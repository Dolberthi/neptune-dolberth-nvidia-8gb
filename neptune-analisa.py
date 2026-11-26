"""Resumo de um log do Neptune_VI (somente leitura): frames no mundo, profiler da thread
victory-submit, clamps, relogio da placa, RAM/VRAM. Uso: python -I analisa.py <log> [rotulo]"""
import re, sys, statistics as st

path = sys.argv[1]
label = sys.argv[2] if len(sys.argv) > 2 else path
ansi = re.compile(r'\x1b\[[0-9;]*m')
frame_re = re.compile(r'host: ([\d.]+) fps, ([\d.]+) ms/frame \(([\d.]+) preparing: copies ([\d.]+) ms ([\d.]+) MB, textures ([\d.]+) ms ([\d.]+) MB; ([\d.]+) on the GPU; ([\d.]+) copying back ([\d.]+) MB\), (\d+) draws/frame, dropped (\d+) without a host pipeline')
kv = re.compile(r'(\w+)=([\d.]+)')
frames, prof, last = [], [], {}
keys = {
    'clamp': 'indirect records per frame',
    'clock': "the card's clock per frame",
    'ram': 'ram line: process',
    'ramsh': 'ram line (shaders)',
    'ask': 'title memory asked about per frame',
    'guards': 'guards per frame',
    'ahead': 'submissions sent ahead per frame',
    'relay': 'the relay per frame',
    'refused': 'windows outside buffers turned down',
    'tex': 'textures picked by index, the queue',
}
world = False
with open(path, encoding='utf-8', errors='replace') as f:
    for raw in f:
        l = ansi.sub('', raw)
        m = frame_re.search(l)
        if m:
            draws = int(m.group(11))
            world = draws > 1500
            if world:
                frames.append(dict(ts=l[11:19], fps=float(m.group(1)), ms=float(m.group(2)), prep=float(m.group(3)),
                                   copies=float(m.group(4)), copies_mb=float(m.group(5)), gpu=float(m.group(8)),
                                   back=float(m.group(9)), back_mb=float(m.group(10)), draws=draws, dropped=int(m.group(12))))
            continue
        if not world:
            continue
        if 'neptune profile ms/frame:' in l:
            prof.append({k: float(v) for k, v in kv.findall(l.split('ms/frame:')[1])})
            continue
        for k, needle in keys.items():
            if needle in l:
                last[k] = l.split(': ', 1)[1].strip() if ': ' in l else l.strip()

print(f'===== {label} =====')
if not frames:
    print('sem frames de mundo (>1500 draws)')
    sys.exit()
ms = [f['ms'] for f in frames]
print(f"frames de mundo: {len(frames)} linhas ({frames[0]['ts']}..{frames[-1]['ts']} UTC) | ms/frame mediana {st.median(ms):.0f} p10 {sorted(ms)[len(ms)//10]:.0f} p90 {sorted(ms)[len(ms)*9//10]:.0f} | fps medio {st.mean(f['fps'] for f in frames):.1f}")
for k in ('prep', 'copies', 'copies_mb', 'gpu', 'back', 'back_mb', 'draws', 'dropped'):
    print(f"  {k:9s} mediana {st.median(f[k] for f in frames):8.1f}")
if prof:
    tail = prof[-20:]
    avg = {k: st.mean(p.get(k, 0.0) for p in tail) for k in tail[-1]}
    order = sorted(((v, k) for k, v in avg.items() if k not in ('submissions', 'steps', 'ahead_due', 'sync_mirrored', 'lines', 'idle')), reverse=True)
    print(f"  submit thread (media de {len(tail)} linhas): ocupada {avg.get('lines',0):.1f} ms, ociosa {avg.get('idle',0):.1f} ms, {avg.get('submissions',0):.0f} submissoes")
    print('   ' + ' | '.join(f'{k} {v:.1f}' for v, k in order[:12]))
for k in keys:
    if k in last:
        print(f'  [{k}] {last[k][:700]}')
