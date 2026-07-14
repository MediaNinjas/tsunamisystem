// supabase/functions/create-checkout/index.ts
//
// Creates a Stripe Checkout session so a user can pay for Tsunami access.
// Called from the app's front end when someone clicks the "Pay with Card" button.
//
// Checkout Sessions do NOT support automatic_payment_methods (that is PaymentIntent-only).
// Use payment_method_types instead. Apple Pay / Google Pay appear under "card" when
// enabled in the Stripe Dashboard; add cashapp so Cash App Pay shows when available.
//
// Required secrets (set with: supabase secrets set KEY=value):
//   STRIPE_SECRET_KEY   - your Stripe secret key (starts with sk_)
//   TSUNAMI_PRICE_ID    - the Stripe Price ID for the one-time product
//                         (create this in Stripe Dashboard -> Product catalog -> Add product)
//   SITE_URL            - https://tsunamiapp.medianinjas.tv (no trailing slash)
//                         DO NOT use bare medianinjas.tv — that is a separate AV site.

import Stripe from "npm:stripe@17";
import { createClient } from "npm:@supabase/supabase-js@2";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-11-20.acacia",
});

// Canonical Tsunami app URL. Never use bare medianinjas.tv (unrelated AV site).
const TSUNAMI_DEFAULT_SITE_URL = "https://tsunamiapp.medianinjas.tv";
const ALLOWED_SITE_ORIGINS = new Set([
  "https://tsunamiapp.medianinjas.tv",
  "https://tsunamisystem.netlify.app",
]);

function resolveSiteUrl(raw: string | undefined): string {
  const candidate = (raw || "").trim().replace(/\/$/, "");
  if (candidate && ALLOWED_SITE_ORIGINS.has(candidate)) return candidate;
  if (candidate && !ALLOWED_SITE_ORIGINS.has(candidate)) {
    console.warn(
      `SITE_URL "${candidate}" is not an allowed Tsunami origin; using ${TSUNAMI_DEFAULT_SITE_URL}`
    );
  }
  return TSUNAMI_DEFAULT_SITE_URL;
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(JSON.stringify({ error: "Missing authorization" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: userError } = await supabase.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const siteUrl = resolveSiteUrl(Deno.env.get("SITE_URL"));

    const session = await stripe.checkout.sessions.create({
      mode: "payment",
      // Checkout API: list methods explicitly (automatic_payment_methods is invalid here).
      // "card" also covers Apple Pay / Google Pay when those are enabled in the Dashboard.
      payment_method_types: ["card", "cashapp"],
      line_items: [
        {
          price: Deno.env.get("TSUNAMI_PRICE_ID")!,
          quantity: 1,
        },
      ],
      // Pass the user's id through so the webhook knows who paid
      client_reference_id: user.id,
      customer_email: user.email,
      success_url: `${siteUrl}/?stripe_success=1#cards`,
      cancel_url: `${siteUrl}/?stripe_cancel=1`,
    });

    return new Response(JSON.stringify({ url: session.url }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("create-checkout error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
