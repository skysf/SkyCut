/** @OnlyCurrentDoc */
// SkyCut website email sign-ups. Each new address becomes a row in the first tab of this spreadsheet.
// Deploy as a web app: Execute as "Me", Who has access "Anyone". Only the skycut.app server
// calls this, and every call must carry the shared secret below.
// If you edit this code later: Deploy → Manage deployments → Edit → Version "New version".
const SECRET = 'REPLACE_WITH_SECRET';
const HEADERS = ['Email', 'Newsletter', 'Intel Mac', 'Windows', 'Language', 'Signed up', 'Updated'];
const LANGUAGES = ['en', 'zh', 'de', 'es'];

function doPost(e) {
  let body;
  try {
    body = JSON.parse(e.postData.contents);
  } catch (err) {
    return reply({ok: false, error: 'bad_request'});
  }
  if (!body || body.secret !== SECRET) return reply({ok: false, error: 'forbidden'});
  const email = String(body.email || '').trim().toLowerCase();
  // The first character may not start a spreadsheet formula (= + - @).
  if (email.length > 254 || !/^[^@\s=+\-][^@\s]*@[^@\s]+\.[^@\s]+$/.test(email)) {
    return reply({ok: false, error: 'bad_email'});
  }
  const language = LANGUAGES.indexOf(body.language) >= 0 ? body.language : '';
  const yes = flag => (flag === true ? 'yes' : '');
  const lock = LockService.getScriptLock();
  lock.waitLock(10000);
  try {
    const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheets()[0];
    if (sheet.getLastRow() === 0) sheet.appendRow(HEADERS);
    const now = new Date();
    const last = sheet.getLastRow();
    const emails = last > 1
      ? sheet.getRange(2, 1, last - 1, 1).getDisplayValues().map(row => row[0].trim().toLowerCase())
      : [];
    const index = emails.indexOf(email);
    if (index < 0) {
      sheet.appendRow([email, yes(body.newsletter), yes(body.intel), yes(body.windows), language, now, now]);
    } else {
      // Signing up again only adds choices; it never removes one.
      const row = index + 2;
      const old = sheet.getRange(row, 2, 1, 4).getDisplayValues()[0];
      sheet.getRange(row, 2, 1, 4).setValues([[
        old[0] || yes(body.newsletter),
        old[1] || yes(body.intel),
        old[2] || yes(body.windows),
        language || old[3],
      ]]);
      sheet.getRange(row, 7).setValue(now);
    }
  } finally {
    lock.releaseLock();
  }
  return reply({ok: true});
}

function reply(value) {
  return ContentService.createTextOutput(JSON.stringify(value)).setMimeType(ContentService.MimeType.JSON);
}
