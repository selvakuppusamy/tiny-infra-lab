const http = require('http')

const server = http.createServer((req, res) => {
  if (req.url === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' })
    res.end(JSON.stringify({
      status: 'ok',
      version: process.env.APP_VERSION ?? 'local'
    }))
    return
  }

  res.writeHead(200, { 'Content-Type': 'text/plain' })
  res.end('Hello from tiny-infra-lab\n')
})

server.listen(3000, '0.0.0.0', () => {
  console.log('Tiny app listening on port 3000')
})
