# Keep the background auth.test (Slink.Identity.prewarm, fired by the
# transports) off the real network in tests. Identity tests override this.
Application.put_env(:slink, :identity_fetch, fn _token -> {:error, :not_stubbed} end)

ExUnit.start()
