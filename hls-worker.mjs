// LiveYou · Conversor de videos a HLS (corre en GitHub Actions, gratis).
// Uso:  node scripts/hls-worker.mjs check   → cuenta videos pendientes (y libera los que quedaron "processing")
//       node scripts/hls-worker.mjs         → convierte hasta MAX_PER_RUN videos pendientes
import { spawn } from "node:child_process";
import { mkdirSync, readFileSync, readdirSync, rmSync, createWriteStream, appendFileSync, statSync } from "node:fs";
import { pipeline } from "node:stream/promises";
import { Readable } from "node:stream";
import { join, extname } from "node:path";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";

const SB = process.env.SUPABASE_URL, KEY = process.env.SUPABASE_SERVICE_KEY;
const MAX_PER_RUN = Number(process.env.MAX_PER_RUN || 3);
const RENDITIONS = (process.env.RENDITIONS || "480").split(",").map(Number).filter(Boolean); // ej. "360,720"
const MAX_TRIES = 3;
const kbps = h => (h <= 240 ? 400 : h <= 360 ? 700 : h <= 480 ? 1100 : h <= 720 ? 2500 : 5000);

/* ---------- utilidades ---------- */
function run(cmd, args){
  return new Promise((ok, fail) => {
    const p = spawn(cmd, args); let out = "", err = "";
    p.stdout.on("data", d => out += d); p.stderr.on("data", d => err += d);
    p.on("error", fail);
    p.on("close", c => c === 0 ? ok(out) : fail(new Error(cmd + " falló (" + c + "): " + err.slice(-600))));
  });
}
async function rest(path, opts = {}){
  const r = await fetch(SB + "/rest/v1/" + path, { ...opts, headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": "application/json", ...(opts.headers || {}) } });
  if (!r.ok) throw new Error("REST " + r.status + ": " + (await r.text()).slice(0, 300));
  return r.status === 204 ? null : r.json();
}
const patch = (id, body) => rest("videos?id=eq." + id, { method: "PATCH", body: JSON.stringify(body) });

/* ---------- conversión con ffmpeg ---------- */
export async function convert(input, outDir, renditions = RENDITIONS){
  const info = JSON.parse(await run("ffprobe", ["-v", "error", "-print_format", "json", "-show_streams", input]));
  const v = info.streams.find(s => s.codec_type === "video");
  if (!v) throw new Error("El archivo no tiene video");
  const hasAudio = info.streams.some(s => s.codec_type === "audio");
  const short = Math.min(v.width, v.height);
  // Nunca se agranda el video: si es más chico que lo pedido, se usa su tamaño real.
  let hs = [...new Set(renditions.map(h => Math.min(h, short - (short % 2))))].sort((a, b) => a - b);
  if (!hs.length) hs = [short - (short % 2)];
  const n = hs.length;
  // Se escala por el lado corto, así sirve igual para videos verticales (celular) y horizontales.
  const sc = h => `scale=w='if(gt(iw\\,ih)\\,-2\\,${h})':h='if(gt(iw\\,ih)\\,${h}\\,-2)'`;
  let fc = n > 1 ? `[0:v]split=${n}${hs.map((_, i) => `[s${i}]`).join("")};` : `[0:v]null[s0];`;
  fc += hs.map((h, i) => `[s${i}]${sc(h)}[o${i}]`).join(";");
  const args = ["-y", "-i", input, "-filter_complex", fc];
  hs.forEach((_, i) => args.push("-map", `[o${i}]`));
  if (hasAudio) hs.forEach(() => args.push("-map", "0:a:0"));
  args.push("-c:v", "libx264", "-preset", "veryfast", "-profile:v", "main", "-pix_fmt", "yuv420p", "-force_key_frames", "expr:gte(t,n_forced*4)");
  hs.forEach((h, i) => args.push(`-b:v:${i}`, kbps(h) + "k", `-maxrate:v:${i}`, Math.round(kbps(h) * 1.1) + "k", `-bufsize:v:${i}`, kbps(h) * 2 + "k"));
  if (hasAudio) args.push("-c:a", "aac", "-ac", "2", "-b:a", "96k");
  hs.forEach((_, i) => mkdirSync(join(outDir, String(i)), { recursive: true }));
  args.push("-f", "hls", "-hls_time", "4", "-hls_playlist_type", "vod", "-hls_flags", "independent_segments",
    "-hls_segment_filename", join(outDir, "%v", "seg_%03d.ts"), "-master_pl_name", "master.m3u8",
    "-var_stream_map", hs.map((_, i) => hasAudio ? `v:${i},a:${i}` : `v:${i}`).join(" "), join(outDir, "%v", "index.m3u8"));
  await run("ffmpeg", args);
  return hs;
}

/* ---------- Supabase Storage ---------- */
const TYPES = { ".m3u8":"application/vnd.apple.mpegurl", ".ts":"video/mp2t" };
function walk(dir, base = ""){
  return readdirSync(dir).flatMap(f => { const p = join(dir, f), rel = base ? base + "/" + f : f; return statSync(p).isDirectory() ? walk(p, rel) : [rel]; });
}
async function putFile(remote, file){
  const body = readFileSync(file);
  for (let t = 1; t <= 3; t++){
    const r = await fetch(SB + "/storage/v1/object/hls/" + remote.split("/").map(encodeURIComponent).join("/"), { method:"POST", body,
      headers: { apikey: KEY, Authorization: "Bearer " + KEY, "Content-Type": TYPES[extname(file)] || "application/octet-stream", "x-upsert": "true", "cache-control": "max-age=31536000" } });
    if (r.ok) return;
    if (t === 3) throw new Error("Subida " + r.status + " " + remote + ": " + (await r.text()).slice(0, 200));
    await new Promise(z => setTimeout(z, 1000 * t));
  }
}
async function uploadAll(outDir, prefix){
  const files = walk(outDir); let i = 0;
  await Promise.all(Array.from({ length: 6 }, async () => { while (i < files.length){ const f = files[i++]; await putFile(prefix + "/" + f, join(outDir, f)); } }));
  return files.length;
}

/* ---------- flujo principal ---------- */
async function processRow(row){
  const ext = extname(row.path || "").toLowerCase();
  if (ext === ".flv" || !row.url){ await patch(row.id, { hls_status:"skip" }); return console.log("saltado (no es MP4):", row.id); }
  const work = join(tmpdir(), "hls_" + row.id), src = join(work, "src" + (ext || ".mp4")), out = join(work, "out");
  rmSync(work, { recursive:true, force:true }); mkdirSync(out, { recursive:true });
  try {
    const r = await fetch(row.url); if (!r.ok) throw new Error("No se pudo descargar el video (" + r.status + ")");
    await pipeline(Readable.fromWeb(r.body), createWriteStream(src));
    const hs = await convert(src, out);
    const prefix = row.user_id + "/" + row.id;
    const nf = await uploadAll(out, prefix);
    await patch(row.id, { hls_status:"ready", hls_url: SB + "/storage/v1/object/public/hls/" + prefix + "/master.m3u8", hls_error:null });
    console.log("listo:", row.id, hs.join("p,") + "p,", nf, "archivos");
  } catch (e) {
    const fin = (row.hls_tries || 0) + 1 >= MAX_TRIES;
    await patch(row.id, { hls_status: fin ? "error" : "pending", hls_error: String(e.message).slice(0, 500) }).catch(() => {});
    console.error("falló:", row.id, e.message);
  } finally { rmSync(work, { recursive:true, force:true }); }
}

async function main(){
  if (!SB || !KEY){ console.error("Faltan SUPABASE_URL y SUPABASE_SERVICE_KEY"); process.exit(1); }
  if (process.argv[2] === "check"){
    await rest("videos?hls_status=eq.processing", { method:"PATCH", body: JSON.stringify({ hls_status:"pending" }) }); // por si una corrida anterior se cortó
    const p = await rest("videos?hls_status=eq.pending&hls_tries=lt." + MAX_TRIES + "&select=id&limit=1");
    const n = p.length ? 1 : 0; console.log("pendientes:", n);
    if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, "pending=" + n + "\n");
    return;
  }
  const tried = []; // un video que falla se reintenta en la próxima corrida, no en esta
  for (let k = 0; k < MAX_PER_RUN; k++){
    const skip = tried.length ? "&id=not.in.(" + tried.map(i => '"' + i + '"').join(",") + ")" : "";
    const rows = await rest("videos?hls_status=eq.pending&hls_tries=lt." + MAX_TRIES + skip + "&select=id,user_id,path,url,hls_tries&order=created_at.asc&limit=1");
    if (!rows.length) break;
    const row = rows[0]; tried.push(row.id);
    const got = await rest("videos?id=eq." + row.id + "&hls_status=eq.pending", { method:"PATCH", headers:{ Prefer:"return=representation" }, body: JSON.stringify({ hls_status:"processing", hls_tries:(row.hls_tries || 0) + 1 }) });
    if (!got.length) continue;
    await processRow(row);
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main().catch(e => { console.error(e); process.exit(1); });
