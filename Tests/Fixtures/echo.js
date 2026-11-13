BareKit.IPC.on('data', (data) => BareKit.IPC.write(data)).write(Buffer.from('READY'))
