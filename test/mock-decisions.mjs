// 테스트용 가짜 Decisions API 서버. 제어 파일에 적힌 noul 값을 그대로 돌려준다.
import http from 'node:http';
import fs from 'node:fs';
const ctl = process.argv[2];
const srv = http.createServer((req, res) => {
  let b = '';
  req.on('data', (d) => (b += d));
  req.on('end', () => {
    let body;
    try { body = JSON.parse(b); } catch { res.writeHead(400); return res.end('{"error":{"code":"bad_request"}}'); }
    const key = req.headers['x-goog-api-key'];
    const q = Object.values(body.questions || {})[0] || {};
    fs.appendFileSync(ctl + '.log', JSON.stringify({ url: req.url, method: req.method, key, model: body.model,
      qkeys: Object.keys(body.questions || {}), qtype: q.type, hasCriteria: !!(q.criteria && q.criteria.true_description),
      inputLen: (body.input || '').length }) + '\n');
    if (!key) { res.writeHead(401); return res.end('{"error":{"code":"unauthenticated"}}'); }
    const noul = Number(fs.readFileSync(ctl, 'utf8').trim());
    const answers = {};
    for (const k of Object.keys(body.questions)) answers[k] = { type: 'noul', noul, confidence: Math.max(noul, 1 - noul) };
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ answers, usage: { total_input_tokens: 100, total_output_tokens: 0, total_tokens: 100 } }));
  });
});
srv.listen(0, '127.0.0.1', () => console.log(srv.address().port));
