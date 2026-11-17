// Answers every JSON-RPC request with the result "pong".
const ipc = BareKit.IPC
let buf = Buffer.alloc(0)
ipc.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk])
  while (buf.length >= 4) {
    const len = buf.readUInt32BE(0)
    if (buf.length < 4 + len) break
    const request = JSON.parse(buf.slice(4, 4 + len).toString())
    buf = buf.slice(4 + len)
    const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { result: 'pong' } }))
    const header = Buffer.allocUnsafe(4)
    header.writeUInt32BE(body.length, 0)
    ipc.write(Buffer.concat([header, body]))
  }
})
