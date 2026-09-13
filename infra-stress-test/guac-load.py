#!/usr/bin/env python3
"""Ouvre N bureaux Guacamole en parallèle, comme N participants dans leur navigateur.

Pour chaque compte : login sur l'API REST, puis tunnel WebSocket sur sa connexion
« Desktop <user> ». Le client consomme le flux d'affichage (c'est ce flux que
guacd encode : le vrai coût CPU côté serveur), répond aux `sync` comme le fait
guacamole-common-js, et envoie un `nop` toutes les 5 s. Il bouge la souris
toutes les 30 s pour empêcher l'écran de veille XFCE.

  ./guac-load.py https://training.k8s-school.fr accounts.txt 1800
  accounts.txt : une ligne « user password » par bureau ; durée en secondes.
Sortie : une ligne par minute et par compte, octets reçus et instructions.
"""
import asyncio, sys, time, ssl, json
import requests, websockets

BASE, ACCOUNTS, DURATION = sys.argv[1], sys.argv[2], int(sys.argv[3])
W, H = 1280, 720

def parse(buf):
    """Découpe le protocole Guacamole : « 4.sync,8.12345678; ». Rend (instructions, reste)."""
    out = []
    while True:
        i = 0; args = []
        try:
            while True:
                dot = buf.index('.', i)
                n = int(buf[i:dot]); s = dot + 1
                args.append(buf[s:s + n]); i = s + n
                if buf[i] == ';': out.append(args); buf = buf[i + 1:]; break
                if buf[i] != ',': raise ValueError(buf[:40])
                i += 1
        except (ValueError, IndexError):
            return out, buf

def enc(*args):
    return ''.join(f'{len(a)}.{a},' for a in args)[:-1] + ';'

async def desktop(user, password, log):
    r = requests.post(f'{BASE}/api/tokens', data={'username': user, 'password': password}, timeout=30)
    r.raise_for_status()
    tok = r.json()['authToken']; ds = r.json()['dataSource']
    conns = requests.get(f'{BASE}/api/session/data/{ds}/connections', params={'token': tok}, timeout=30).json()
    cid = next(c['identifier'] for c in conns.values() if c['name'] == f'Desktop {user}')
    url = (f"{BASE.replace('https', 'wss').replace('http', 'ws')}/websocket-tunnel?token={tok}"
           f"&GUAC_DATA_SOURCE={ds}&GUAC_ID={cid}&GUAC_TYPE=c&GUAC_WIDTH={W}&GUAC_HEIGHT={H}&GUAC_DPI=96"
           f"&GUAC_IMAGE=image/jpeg&GUAC_IMAGE=image/png&GUAC_IMAGE=image/webp")
    t0 = time.time(); nbytes = 0; ninstr = 0; buf = ''; last_report = t0; last_nop = t0; last_mouse = t0; x = 100
    async with websockets.connect(url, subprotocols=['guacamole'], max_size=None, ssl=ssl.create_default_context() if url.startswith('wss') else None) as ws:
        log(f'{user}: connecté (connexion {cid})')
        while time.time() - t0 < DURATION:
            try:
                msg = await asyncio.wait_for(ws.recv(), timeout=1.0)
                nbytes += len(msg); buf += msg
                instrs, buf = parse(buf); ninstr += len(instrs)
                for ins in instrs:
                    if ins[0] == 'sync': await ws.send(enc('sync', ins[1]))
                    elif ins[0] == 'error': log(f'{user}: ERROR {ins[1:]}'); return
                    elif ins[0] == 'disconnect': log(f'{user}: disconnect'); return
            except asyncio.TimeoutError:
                pass
            now = time.time()
            if now - last_nop > 5: await ws.send(enc('nop')); last_nop = now
            if now - last_mouse > 30:
                x = 100 if x > 600 else x + 50
                await ws.send(enc('mouse', str(x), '300', '0')); last_mouse = now
            if now - last_report > 60:
                log(f'{user}: {int(now - t0)}s {nbytes/1e6:.1f} Mo reçus, {ninstr} instructions')
                last_report = now
        await ws.send(enc('disconnect'))
    log(f'{user}: fin, {nbytes/1e6:.1f} Mo en {int(time.time() - t0)}s')

async def main():
    accounts = [l.split() for l in open(ACCOUNTS) if l.strip()]
    def log(m): print(f'[{time.strftime("%H:%M:%S")}] {m}', flush=True)
    tasks = []
    for i, (u, p) in enumerate(accounts):
        await asyncio.sleep(3)   # les gens n'arrivent pas tous à la même seconde
        tasks.append(asyncio.create_task(desktop(u, p, log)))
    res = await asyncio.gather(*tasks, return_exceptions=True)
    for (u, _), r in zip(accounts, res):
        if isinstance(r, Exception): log(f'{u}: EXCEPTION {r!r}')

asyncio.run(main())
