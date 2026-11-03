# Brief for the Proxmox Expert bot: put a usage meter in front of hex's Ollama

**Why.** Ollama keeps no per-request token counts, so nothing on hex can say how much of
the box every client uses. Burn Bar's HEX card can show it (tokens, requests, speed, who and
which model, in-flight now) if a transparent counting proxy sits in front of Ollama. The proxy
(`nano/ollama-meter.py` in github.com/nixfred/burnbar) forwards every byte unchanged, reads only the
token counts from each reply, and never stores prompt or reply text. It adds
`GET /_meter/usage`, answered by the proxy itself.

**What changes on hex.** Only Ollama's own address, inside the Ollama container (CT 300 in
the rebuild notes, Ollama at <ollama-lan-address>:11434). Clients and `tailscale serve` keep using
`<ollama-lan-address>:11434`; nothing else moves.

I have not seen the container's current `ollama.service.d/override.conf`, so the steps name
what to change, not exact file contents. You know the real file.

## Steps (inside the Ollama container)

1. Copy the meter: `install -D nano/ollama-meter.py /usr/local/lib/burnbar/ollama-meter.py`
   (single file, Python 3 standard library only).
2. Install `hex/ollama-meter.service` as `/etc/systemd/system/ollama-meter.service`.
3. In Ollama's systemd override, change its listen address to `OLLAMA_HOST=127.0.0.1:11435`.
   Keep every other setting (models path, keep-alive, num_parallel, GPU/Vulkan variables).
4. `systemctl daemon-reload && systemctl restart ollama && systemctl enable --now ollama-meter`.

## Check

```
curl -s http://<ollama-lan-address>:11434/api/version        # still answers (through the meter)
curl -s 'http://<ollama-lan-address>:11434/_meter/usage?window=60&buckets=6' | head -c 300   # {"v":1,...}
~/bin/hex chat "say OK"                             # from gus: works as before
```
Then from any tailnet machine: `curl -s 'https://<hex-tailnet-name>/_meter/usage?window=60'`.
Burn Bar picks it up on its own within a minute; nothing to configure.

## Rollback (one step each)

`systemctl disable --now ollama-meter`, restore the override's old `OLLAMA_HOST`, restart ollama.

## Known limits

- Requests that arrive through `tailscale serve` carry the proxy host's address, so clients are named by
  the `Tailscale-User-Login` header when serve adds it (tailnet users), else `X-Forwarded-For`,
  else the peer address. Headless/tagged nodes may all appear as one address.
- Streaming and long generations are relayed chunk by chunk; the meter's upstream timeout is 10 minutes
  of silence, not of total time. Model loads of 40 to 170 s are inside that.
- The meter is one more process in the request path. If it dies, systemd restarts it within a second;
  clients see a connection error for that second.
- Records stay 48 h in memory and in `/var/lib/ollama-meter/usage.jsonl` (rotates at 8 MB).
