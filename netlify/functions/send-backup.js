exports.handler = async function(event) {
  if (event.httpMethod !== "POST") {
    return { statusCode: 405, body: "Method Not Allowed" };
  }

  try {
    var body = JSON.parse(event.body);
    var email = body.email;
    var csv = body.csv;
    var date = new Date().toISOString().slice(0,10);

    if (!email || !csv) {
      return { statusCode: 400, body: "Missing email or csv" };
    }

    var attachment = Buffer.from(csv).toString("base64");

    var response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + process.env.RESEND_API_KEY
      },
      body: JSON.stringify({
        from: "Tsunami System <noreply@tsunamiapp.medianinjas.tv>",
        to: [email],
        subject: "Tsunami System — Your Backup",
        html: `
          <div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;background:#0a0a0a;color:#fff;padding:30px;border-radius:12px;">
            <h1 style="font-size:28px;letter-spacing:0.2em;color:#fff;margin-bottom:4px;">TSUNAMI SYSTEM</h1>
            <p style="color:rgba(255,255,255,0.5);font-size:13px;margin-top:0;">Debt Payoff Backup — ${date}</p>
            <hr style="border:none;border-top:1px solid rgba(255,255,255,0.1);margin:20px 0;">
            <p style="color:rgba(255,255,255,0.8);font-size:14px;line-height:1.6;">Your backup is attached as a CSV file. Keep this email safe — you can import it back into the app anytime.</p>
            <hr style="border:none;border-top:1px solid rgba(255,255,255,0.1);margin:20px 0;">
            <p style="color:rgba(255,255,255,0.8);font-size:14px;line-height:1.7;">A quick note from Vincent —</p>
            <p style="color:rgba(255,255,255,0.7);font-size:13px;line-height:1.8;">I built the Tsunami System because I needed it myself. Right now we're using email as your backup because we're building this thing on demand — real people using it, real feedback, real life. When we have enough support we'll build out the full cloud backend. Automatic sync, restore points, access from any device. No workarounds.</p>
            <p style="color:rgba(255,255,255,0.7);font-size:13px;line-height:1.8;">You're an early adopter and that means everything. You're not just using this — you're helping build it.</p>
            <p style="color:rgba(255,255,255,0.7);font-size:13px;line-height:1.8;">To restore your data if you ever need it — open the app, tap Ledger, tap Import CSV, and select the file attached to this email. Your cards come right back exactly where you left off.</p>
            <p style="color:rgba(255,255,255,0.5);font-size:13px;">Keep going. You're closer than you think.</p>
            <p style="color:rgba(255,255,255,0.5);font-size:13px;">— Vincent</p>
            <hr style="border:none;border-top:1px solid rgba(255,255,255,0.1);margin:20px 0;">
            <p style="color:rgba(255,255,255,0.5);font-size:13px;text-align:center;margin-bottom:8px;">This is what you're working toward.</p>
            <img src="https://www.dropbox.com/scl/fi/j9luaslyinog7etb0p47r/5-Costa-Rica.jpg?rlkey=990nq7077z80ivcddrovlxiq6&st=lhnp5kw8&raw=1" style="width:100%;border-radius:12px;" alt="Keep going.">
            <p style="color:rgba(255,255,255,0.3);font-size:11px;text-align:center;margin-top:20px;">The Tsunami System — built for real life.</p>
          </div>
        `,
        attachments: [
          {
            filename: "tsunami-backup-" + date + ".csv",
            content: attachment
          }
        ]
      })
    });

    if (response.ok) {
      return { statusCode: 200, body: JSON.stringify({ success: true }) };
    } else {
      var err = await response.text();
      return { statusCode: 500, body: err };
    }

  } catch(e) {
    return { statusCode: 500, body: e.message };
  }
};
