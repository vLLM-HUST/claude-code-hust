import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { startMock, statusMock, logoutMock } = vi.hoisted(() => ({
  startMock: vi.fn(),
  statusMock: vi.fn(),
  logoutMock: vi.fn(),
}))

vi.mock('../api/hustOpenAIOAuth', () => ({
  hustOpenAIOAuthApi: {
    start: startMock,
    status: statusMock,
    logout: logoutMock,
  },
}))

import { useHustOpenAIOAuthStore } from './hustOpenAIOAuthStore'

const initialState = useHustOpenAIOAuthStore.getState()

describe('hustOpenAIOAuthStore', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    startMock.mockReset()
    statusMock.mockReset()
    logoutMock.mockReset()
    useHustOpenAIOAuthStore.setState({
      ...initialState,
      status: null,
      isPolling: false,
      isLoading: false,
      error: null,
    })
  })

  afterEach(() => {
    useHustOpenAIOAuthStore.getState().stopPolling()
    useHustOpenAIOAuthStore.setState(initialState)
    vi.useRealTimers()
  })

  it('login returns authorizeUrl without starting polling', async () => {
    startMock.mockResolvedValue({
      authorizeUrl: 'http://localhost:3456/callback/openai?state=openai-state',
      state: 'openai-state',
    })

    const result = await useHustOpenAIOAuthStore.getState().login()

    expect(result.authorizeUrl).toContain('/callback/openai')
    expect(useHustOpenAIOAuthStore.getState().isPolling).toBe(false)
  })

  it('startPolling stops after OpenAI OAuth status becomes logged in', async () => {
    statusMock
      .mockResolvedValueOnce({ loggedIn: false })
      .mockResolvedValueOnce({
        loggedIn: true,
        expiresAt: Date.now() + 60_000,
        email: 'user@example.com',
        accountId: 'acct_123',
      })

    useHustOpenAIOAuthStore.getState().startPolling()
    expect(useHustOpenAIOAuthStore.getState().isPolling).toBe(true)

    await vi.advanceTimersByTimeAsync(2_000)
    expect(useHustOpenAIOAuthStore.getState().isPolling).toBe(true)

    await vi.advanceTimersByTimeAsync(2_000)
    expect(useHustOpenAIOAuthStore.getState().status).toMatchObject({
      loggedIn: true,
      email: 'user@example.com',
      accountId: 'acct_123',
    })
    expect(useHustOpenAIOAuthStore.getState().isPolling).toBe(false)
  })

  it('logout clears status and stops polling', async () => {
    logoutMock.mockResolvedValue({ ok: true })
    useHustOpenAIOAuthStore.setState({
      status: {
        loggedIn: true,
        expiresAt: Date.now() + 60_000,
        email: 'user@example.com',
        accountId: 'acct_123',
      },
    })
    useHustOpenAIOAuthStore.getState().startPolling()

    await useHustOpenAIOAuthStore.getState().logout()

    expect(logoutMock).toHaveBeenCalledTimes(1)
    expect(useHustOpenAIOAuthStore.getState().status).toEqual({ loggedIn: false })
    expect(useHustOpenAIOAuthStore.getState().isPolling).toBe(false)
  })
})
