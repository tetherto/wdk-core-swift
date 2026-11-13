const ipc = BareKit.IPC
let buf = Buffer.alloc(0)
ipc.on('data', (chunk) => {
  buf = Buffer.concat([buf, chunk])
  while (buf.length >= 4) {
    const len = buf.readUInt32BE(0)
    if (buf.length < 4 + len) break
    const msg = buf.slice(4, 4 + len)
    buf = buf.slice(4 + len)
    const header = Buffer.allocUnsafe(4)
    header.writeUInt32BE(msg.length, 0)
    ipc.write(Buffer.concat([header, msg]))
  }
})
ipc.write(Buffer.from('READY'))
