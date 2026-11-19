import { afterEach, describe, expect, it } from 'bun:test'
import { buildClientVersion, extractWechatText, sendWechatText, sendWechatTyping, startWechatLoginWithQr, pollWechatLoginWithQr, getWechatUpdates, getWechatConfig } from '../protocol.js'
import { collectWechatMediaCandidates } from '../media.js'

const originalFetch = globalThis.fetch

afterEach(() => {
  globalThis.fetch = originalFetch
})

describe('WeChat login and polling contracts', () => {
  it('reuses a fresh QR and requests a new one only when forced', async () => {
    const requests: string[] = []
    globalThis.fetch = (async (url: Parameters<typeof fetch>[0]) => {
      requests.push(String(url))
      return Response.json({ qrcode: 'qr-token', qrcode_img_content: 'https://unit.invalid/qr.png' })
    }) as typeof fetch
    const first = await startWechatLoginWithQr({ sessionKey: 'unit-qr-reuse', botType: '3&extra=1' })
    expect(await startWechatLoginWithQr({ sessionKey: first.sessionKey })).toMatchObject({ qrcodeUrl: first.qrcodeUrl })
    expect(requests).toHaveLength(1)
    expect(new URL(requests[0]!).searchParams.get('bot_type')).toBe('3&extra=1')
    await startWechatLoginWithQr({ sessionKey: first.sessionKey, force: true })
    expect(requests).toHaveLength(2)
  })

  it('follows the QR gateway redirect and returns confirmed credentials once', async () => {
    const urls: string[] = []
    const responses = [
      { qrcode: 'redirect-qr', qrcode_img_content: 'https://unit.invalid/qr.png' },
      { status: 'scaned_but_redirect', redirect_host: 'gateway.unit.invalid' },
      { status: 'confirmed', bot_token: 'fake-unit-token', ilink_bot_id: 'bot-1', ilink_user_id: 'user-1' },
    ]
    globalThis.fetch = (async (url: Parameters<typeof fetch>[0]) => {
      urls.push(String(url))
      return Response.json(responses.shift())
    }) as typeof fetch
    const { sessionKey } = await startWechatLoginWithQr({ sessionKey: 'unit-qr-redirect' })
    expect(await pollWechatLoginWithQr({ sessionKey })).toMatchObject({ connected: false, status: 'scaned_but_redirect' })
    expect(await pollWechatLoginWithQr({ sessionKey })).toMatchObject({
      connected: true, botToken: 'fake-unit-token', accountId: 'bot-1', userId: 'user-1', baseUrl: 'https://gateway.unit.invalid',
    })
    expect(new URL(urls[2]!).hostname).toBe('gateway.unit.invalid')
    expect(await pollWechatLoginWithQr({ sessionKey })).toMatchObject({ connected: false, status: 'not_started' })
  })

  it('does not report a successful login without complete credentials', async () => {
    let first = true
    globalThis.fetch = (async () => {
      const response = first
        ? { qrcode: 'incomplete-qr', qrcode_img_content: 'https://unit.invalid/qr.png' }
        : { status: 'confirmed', bot_token: 'fake-unit-token' }
      first = false
      return Response.json(response)
    }) as typeof fetch
    const { sessionKey } = await startWechatLoginWithQr({ sessionKey: 'unit-qr-incomplete' })
    expect(await pollWechatLoginWithQr({ sessionKey })).toMatchObject({ connected: false, status: 'confirmed' })
  })

  it('keeps a QR session pending when the long poll is aborted', async () => {
    globalThis.fetch = (async () => Response.json({ qrcode: 'waiting-qr', qrcode_img_content: 'https://unit.invalid/qr.png' })) as typeof fetch
    const { sessionKey } = await startWechatLoginWithQr({ sessionKey: 'unit-qr-abort' })
    globalThis.fetch = (async () => { throw new DOMException('aborted', 'AbortError') }) as typeof fetch
    expect(await pollWechatLoginWithQr({ sessionKey })).toMatchObject({ connected: false, status: 'wait' })
  })

  it('rejects malformed QR responses instead of recording an unusable login', async () => {
    globalThis.fetch = (async () => Response.json({ qrcode: 'missing-image' })) as typeof fetch
    await expect(startWechatLoginWithQr({ sessionKey: 'unit-qr-malformed' })).rejects.toThrow('did not include a QR code URL')
    expect(await pollWechatLoginWithQr({ sessionKey: 'unit-qr-malformed' })).toMatchObject({ status: 'not_started' })
  })

  it('preserves the update cursor on a real AbortSignal timeout', async () => {
    globalThis.fetch = ((_url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => new Promise<Response>((_resolve, reject) => {
      expect(JSON.parse(String(init?.body)).get_updates_buf).toBe('cursor-7')
      init?.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true })
    })) as typeof fetch
    expect(await getWechatUpdates({ baseUrl: 'https://unit.invalid', token: 'fake-unit-token', getUpdatesBuf: 'cursor-7', timeoutMs: 1 }))
      .toEqual({ ret: 0, msgs: [], get_updates_buf: 'cursor-7' })
  })

  it('returns update messages and the next cursor from successful polls', async () => {
    globalThis.fetch = (async () => Response.json({ ret: 0, msgs: [{ message_id: 42 }], get_updates_buf: 'cursor-8' })) as typeof fetch
    expect(await getWechatUpdates({ baseUrl: 'https://unit.invalid', token: 'fake-unit-token' }))
      .toMatchObject({ msgs: [{ message_id: 42 }], get_updates_buf: 'cursor-8' })
  })

  it('sends config requests with UTF-8 byte lengths and trimmed authentication', async () => {
    globalThis.fetch = (async (url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      expect(new URL(String(url)).pathname).toBe('/base/ilink/bot/getconfig')
      const headers = new Headers(init?.headers)
      expect(headers.get('Authorization')).toBe('Bearer fake-unit-token')
      expect(headers.get('Content-Length')).toBe(String(Buffer.byteLength(String(init?.body))))
      expect(JSON.parse(String(init?.body))).toMatchObject({ ilink_user_id: '用户', context_token: 'ctx-1' })
      return Response.json({ ret: 0, typing_ticket: 'ticket-1' })
    }) as typeof fetch
    expect(await getWechatConfig({ baseUrl: 'https://unit.invalid/base', token: ' fake-unit-token ', ilinkUserId: '用户', contextToken: 'ctx-1' }))
      .toMatchObject({ typing_ticket: 'ticket-1' })
  })
})

describe('WeChat protocol helpers', () => {
  it('encodes iLink client versions like the OpenClaw Weixin plugin', () => {
    expect(buildClientVersion('2.1.7')).toBe((2 << 16) | (1 << 8) | 7)
    expect(buildClientVersion('1.0.11')).toBe(65547)
  })

  it('extracts plain text from WeChat message items', () => {
    expect(extractWechatText([
      { type: 1, text_item: { text: 'hello' } },
    ])).toBe('hello')
  })

  it('extracts voice transcription when text items are absent', () => {
    expect(extractWechatText([
      { type: 3, voice_item: { text: 'voice text' } },
    ])).toBe('voice text')
  })

  it('preserves quoted text context', () => {
    expect(extractWechatText([
      {
        type: 1,
        text_item: { text: 'reply' },
        ref_msg: {
          title: 'quote title',
          message_item: { type: 1, text_item: { text: 'quoted body' } },
        },
      },
    ])).toBe('[引用: quote title | quoted body]\nreply')
  })

  it('collects image and file media candidates from message items', () => {
    expect(collectWechatMediaCandidates([
      {
        type: 2,
        msg_id: 'img-1',
        image_item: {
          aeskey: '00112233445566778899aabbccddeeff',
          media: {
            full_url: 'https://cdn.example.com/image',
            encrypt_query_param: 'enc=1',
          },
        },
      },
      {
        type: 4,
        msg_id: 'file-1',
        file_item: {
          file_name: 'report.pdf',
          media: {
            full_url: 'https://cdn.example.com/file',
            aes_key: Buffer.from('00112233445566778899aabbccddeeff').toString('base64'),
          },
        },
      },
    ])).toMatchObject([
      {
        kind: 'image',
        name: 'wechat-image-img-1.jpg',
        url: 'https://cdn.example.com/image',
      },
      {
        kind: 'file',
        name: 'report.pdf',
        url: 'https://cdn.example.com/file',
        mimeType: 'application/pdf',
      },
    ])
  })

  it('throws when sendmessage returns a non-zero WeChat ret code', async () => {
    globalThis.fetch = (async () => new Response(JSON.stringify({ ret: 40001, errmsg: 'bad context_token' }), { status: 200 })) as unknown as typeof fetch

    await expect(sendWechatText({
      baseUrl: 'https://api.example.com',
      token: 'token',
      to: 'user',
      text: 'hello',
      contextToken: 'stale-context',
    })).rejects.toThrow('wechatSendMessage returned 40001: bad context_token')
  })

  it('allows successful sendmessage responses', async () => {
    const requests: string[] = []
    globalThis.fetch = (async (_url: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
      requests.push(String(init?.body ?? ''))
      return new Response(JSON.stringify({ ret: 0 }), { status: 200 })
    }) as unknown as typeof fetch

    await sendWechatText({
      baseUrl: 'https://api.example.com',
      token: 'token',
      to: 'user',
      text: 'hello',
      contextToken: 'ctx',
    })

    expect(requests).toHaveLength(1)
    expect(JSON.parse(requests[0]!).msg.context_token).toBe('ctx')
  })

  it('throws when sendtyping returns a non-zero WeChat ret code', async () => {
    globalThis.fetch = (async () => new Response(JSON.stringify({ ret: 42001, errmsg: 'typing ticket expired' }), { status: 200 })) as unknown as typeof fetch

    await expect(sendWechatTyping({
      baseUrl: 'https://api.example.com',
      token: 'token',
      ilinkUserId: 'user',
      typingTicket: 'ticket',
      status: 'typing',
    })).rejects.toThrow('wechatSendTyping returned 42001: typing ticket expired')
  })
})
