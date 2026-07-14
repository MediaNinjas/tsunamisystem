// supabase/functions/delete-account/index.ts
//
// Lets a signed-in user permanently delete their own Tsunami account:
// their cards, their affiliate payout handles (if they ever applied), their
// profiles row, and finally the auth.users row itself. Client-side "delete
// account" in Settings can only null out unlocked/is_admin-protected fields
// via RPC (see 20260714160000_security_layer.sql) so real account deletion
// has to go through a service-role edge function instead.
//
// Required secrets (set with: supabase secrets set KEY=value):
//   SUPABASE_URL               - your project URL
//   SUPABASE_ANON_KEY          - used only to verify the caller's JWT
//   SUPABASE_SERVICE_ROLE_KEY  - the service role key from Supabase Settings -> API
//                                (bypasses RLS; never expose to the front end)

import { createClient } from "npm:@supabase/supabase-js@2";

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

    // User client: only used to verify the caller's JWT and resolve their id.
    const supabaseUser = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: authHeader } } }
    );

    const { data: { user }, error: userError } = await supabaseUser.auth.getUser();
    if (userError || !user) {
      return new Response(JSON.stringify({ error: "Invalid session" }), {
        status: 401,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const userId = user.id;
    const userEmail = user.email ?? null;

    // Admin client: bypasses RLS, required to delete other users' rows and the
    // auth.users row itself. Never expose SUPABASE_SERVICE_ROLE_KEY to the client.
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { error: cardsError } = await supabaseAdmin
      .from("cards")
      .delete()
      .eq("user_id", userId);
    if (cardsError) {
      console.error("delete-account: failed to delete cards row:", cardsError);
    }

    // Affiliates keep historical commission rows for statements/payouts, so we
    // scrub payout handles and mark the record deleted instead of removing it.
    const { error: affiliateError } = await supabaseAdmin
      .from("affiliates")
      .update({
        payout_paypal: null,
        payout_venmo: null,
        payout_cashapp: null,
        deleted_at: new Date().toISOString(),
      })
      .eq("user_id", userId);
    if (affiliateError) {
      console.error("delete-account: failed to scrub affiliate payout handles:", affiliateError);
    }

    const { error: profileError } = await supabaseAdmin
      .from("profiles")
      .delete()
      .eq("id", userId);
    if (profileError) {
      console.error("delete-account: failed to delete profiles row:", profileError);
    }

    const { error: authDeleteError } = await supabaseAdmin.auth.admin.deleteUser(userId);
    if (authDeleteError) {
      console.error("delete-account: failed to delete auth user:", authDeleteError);
      return new Response(JSON.stringify({ error: "Failed to delete account" }), {
        status: 500,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const { error: auditError } = await supabaseAdmin.from("admin_audit_log").insert({
      actor_id: userId,
      action: "delete_account",
      meta: { email: userEmail },
    });
    if (auditError) {
      console.error("delete-account: failed to write audit log:", auditError);
    }

    return new Response(JSON.stringify({ ok: true }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("delete-account error:", err);
    return new Response(JSON.stringify({ error: String(err) }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
