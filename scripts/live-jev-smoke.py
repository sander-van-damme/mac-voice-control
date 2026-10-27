#!/usr/bin/env python3
"""Opt-in API contract probe; generated pixels only, no desktop control or saved key."""
import base64
import json
import os
import struct
import time
import urllib.error
import urllib.request
import uuid
import zlib


def png_chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))


def main():
    key = os.environ.get('TYPESAFE_API_KEY')
    if not key:
        raise SystemExit('Set TYPESAFE_API_KEY in your environment; this opt-in check incurs API usage.')
    # White 320x320 image with one centered red square; no external image dependency.
    pixels = b''.join(b'\0' + b''.join(b'\xff\0\0' if 100 <= x < 220 and 100 <= y < 220 else b'\xff\xff\xff' for x in range(320)) for y in range(320))
    png = b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('>IIBBBBB',320,320,8,2,0,0,0)) + png_chunk(b'IDAT',zlib.compress(pixels)) + png_chunk(b'IEND',b'')
    ref = str(uuid.uuid4())
    body = {'model':'jev-1.14.0','state':{'image':ref},'assets':{ref:{'type':'image','format':'png','data_base64':base64.b64encode(png).decode()}},'questions':{
        'present':{'type':'noul','instructions':'Is a red square visible in image?'},
        'color':{'type':'choice','instructions':'What color is the square in image?','criteria':{'red':'red','blue':'blue','green':'green'}},
        'target':{'type':'box','instructions':'The red square in image'}}}
    request = urllib.request.Request('https://api.typesafe.ai/v1/systemone', data=json.dumps(body).encode(), headers={
        'Authorization':'Bearer '+key,'Content-Type':'application/json','TypeSafe-Danger-Zone-Images':'true'})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request,timeout=30) as response:
            result = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit(f'API probe failed: HTTP {error.code}; response body suppressed.') from None
    assert result['model'] == 'jev-1.14.0', 'Wrong model'
    answers = result['answers']
    assert answers['present']['noul'] >= .9, 'Presence uncertain'
    assert answers['color']['choice'] == 'red', 'Wrong color'
    box = answers['target']['box']
    assert 0 <= box['left'] < box['right'] <= 1 and 0 <= box['top'] < box['bottom'] <= 1, 'Invalid box'
    assert abs((box['left']+box['right'])/2-.5) < .15, 'Bad horizontal localization'
    assert abs((box['top']+box['bottom'])/2-.5) < .15, 'Bad vertical localization'
    print(json.dumps({'passed':True,'latency_ms':round((time.monotonic()-started)*1000),'usage':result.get('usage')}))


if __name__ == '__main__':
    main()
