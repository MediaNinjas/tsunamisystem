// supabase/functions/stripe-webhook/index.ts
//
// Listens for Stripe's "checkout.session.completed" event and, when a real payment
// comes in, generates a single-use code (same system the app already uses for promo
// codes) and unlocks that user's account automatically - no manual step needed.
//
// This is the server-side counterpart to create-checkout. Stripe calls THIS function
// directly (not your app) whenever a payment happens - that's what a webhook is.
//
// Required secrets (set with: supabase secrets set KEY=value):
//   STRIPE_SECRET_KEY          - same key as create-checkout
//   STRIPE_WEBHOOK_SECRET      - starts with whsec_, you get this when you create
//                                the webhook endpoint in the Stripe Dashboard
//   SUPABASE_SERVICE_ROLE_KEY  - the service role key from Supabase Settings -> API
//                                (this is NOT the anon key - it bypasses RLS, so it
//                                must only ever live here on the server, never in
//                                the app's front-end code)
//   SUPABASE_URL               - your project URL

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-11-20.acacia",
});

const supabaseAdmin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

function makePromoCode(): string {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous chars (0/O, 1/I)
  const seg = () => Array.from({ length: 4 }, () => chars[Math.floor(Math.random() * chars.length)]).join("");
  return `TSU-${seg()}-${seg()}`;
}

Deno.serve(async (req) => {
  const signature = req.headers.get("stripe-signature");
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature!,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!
    );
  } catch (err) {
    console.error("Webhook signature verification failed:", err);
    return new Response(`Webhook Error: ${err}`, { status: 400 });
  }

  if (event.type === "checkout.session.completed") {
    const session = event.data.object as Stripe.Checkout.Session;
    const userId = session.client_reference_id;

    if (!userId) {
      console.error("No client_reference_id on session - can't identify buyer:", session.id);
      return new Response("Missing user reference", { status: 400 });
    }

    const code = makePromoCode();

    try {
      // Record the code as used by this buyer (same table the app already reads)
      await supabaseAdmin.from("codes").insert({
        code,
        used: true,
        used_by: userId,
        used_at: new Date().toISOString(),
        stripe_session_id: session.id,
        max_uses: 1,
        use_count: 1,
      });

      // Unlock their account
      await supabaseAdmin
        .from("profiles")
        .update({ unlocked: true, code_used: code })
        .eq("id", userId);

      console.log(`Unlocked user ${userId} via Stripe session ${session.id}`);
    } catch (err) {
      console.error("Failed to unlock user after Stripe payment:", err);
      // Still return 200 so Stripe doesn't keep retrying a payment we did receive -
      // but log loudly so you notice and can unlock manually if this ever happens.
      return new Response("Payment received but unlock failed - check logs", { status: 200 });
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
