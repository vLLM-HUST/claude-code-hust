import { afterEach, beforeEach, describe, expect, it } from 'bun:test'
import crypto from 'node:crypto'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { AttachmentStore } from '../../common/attachment/attachment-store.js'
import { WechatMediaService } from '../media.js'

let root: string
const originalFetch = globalThis.fetch
beforeEach(async () => { root = await mkdtemp(path.join(tmpdir(), 'wechat-media-test-')) })
afterEach(async () => {
  globalThis.fetch = originalFetch
  await rm(root, { recursive: true, force: true })
})

describe('WeChat media staging', () => {
  for (const encoding of ['raw', 'hex'] as const) {
    it(`decrypts AES media using a base64 ${encoding} key and persists the plaintext`, async () => {
      const key = Buffer.from('00112233445566778899aabbccddeeff', 'hex')
      const plaintext = Buffer.from('verified image contents')
      const cipher = crypto.createCipheriv('aes-128-ecb', key, null)
      const encrypted = Buffer.concat([cipher.update(plaintext), cipher.final()])
      globalThis.fetch = (async (url: Parameters<typeof fetch>[0]) => {
        expect(String(url)).toBe('https://cdn.unit.invalid/image')
        return new Response(encrypted)
      }) as typeof fetch
      const service = new WechatMediaService(new AttachmentStore({ root }))
      const file = await service.downloadCandidate({
        kind: 'image', name: 'image.jpg', url: 'https://cdn.unit.invalid/image',
        aesKey: (encoding === 'raw' ? key : Buffer.from(key.toString('hex'))).toString('base64'),
      }, 'session-1')
      expect(file.buffer).toEqual(plaintext)
      expect(await readFile(file.path)).toEqual(plaintext)
      expect(file.size).toBe(plaintext.length)
      expect(file.mimeType).toBe('image/jpeg')
      expect(path.relative(root, file.path)).toBe(path.join('wechat', 'session-1', 'image.jpg'))
    })
  }

  it('uses the CDN query for unencrypted files and stages names inside the session', async () => {
    globalThis.fetch = (async (url: Parameters<typeof fetch>[0]) => {
      expect(new URL(String(url)).searchParams.get('encrypted')).toBe('a+b')
      return new Response('file contents')
    }) as typeof fetch
    const service = new WechatMediaService(new AttachmentStore({ root }))
    const file = await service.downloadCandidate({ kind: 'file', name: '../report.txt', encryptQueryParam: 'encrypted=a%2Bb' }, 'session-2')
    expect(file.buffer.toString()).toBe('file contents')
    expect(file.mimeType).toBe('application/octet-stream')
    expect(path.relative(root, file.path)).toBe(path.join('wechat', 'session-2', 'report.txt'))
  })

  it('rejects missing download URLs without issuing a request', async () => {
    let calls = 0
    globalThis.fetch = (async () => { calls += 1; throw new Error('unexpected network') }) as typeof fetch
    const service = new WechatMediaService(new AttachmentStore({ root }))
    await expect(service.downloadCandidate({ kind: 'file', name: 'missing.txt' }, 'session-3')).rejects.toThrow('missing a download URL')
    expect(calls).toBe(0)
    expect(await readdir(root)).toEqual([])
  })

  it('does not persist failed responses or invalid encryption keys', async () => {
    const service = new WechatMediaService(new AttachmentStore({ root }))
    const candidate = { kind: 'file' as const, name: 'invalid.txt', url: 'https://cdn.unit.invalid/file' }
    globalThis.fetch = (async () => new Response('denied', { status: 403, statusText: 'Forbidden' })) as typeof fetch
    await expect(service.downloadCandidate(candidate, 'session-4')).rejects.toThrow('403 Forbidden')
    globalThis.fetch = (async () => new Response('encrypted')) as typeof fetch
    await expect(service.downloadCandidate({ ...candidate, aesKey: Buffer.from('bad').toString('base64') }, 'session-4')).rejects.toThrow('AES key must decode to 16 bytes')
    expect(await readdir(root)).toEqual([])
  })
})
