import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const response = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json" },
});

Deno.serve(async (request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return response({ error: "Method not allowed." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !anonKey || !serviceKey) return response({ error: "Invitation service is not configured." }, 503);

  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return response({ error: "Sign in as a business owner to invite staff." }, 401);

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  if (authError || !authData.user) return response({ error: "Your session is invalid or expired. Please sign in again." }, 401);

  let input: { business_id?: string; full_name?: string; email?: string; phone?: string | null };
  try { input = await request.json(); } catch { return response({ error: "Invalid request body." }, 400); }
  const businessId = input.business_id?.trim();
  const fullName = input.full_name?.trim();
  const email = input.email?.trim().toLowerCase();
  const phone = input.phone?.trim() || null;
  if (!businessId || !/^[0-9a-f-]{36}$/i.test(businessId)
    || !fullName || fullName.length > 80
    || !email || email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)
    || (phone && phone.length > 32)) return response({ error: "Enter a valid name, email, phone, and business." }, 400);

  const { data: owner, error: ownerError } = await admin.from("business_memberships")
    .select("id").eq("business_id", businessId).eq("user_id", authData.user.id)
    .eq("role", "owner").eq("status", "active").maybeSingle();
  if (ownerError || !owner) return response({ error: "You are not an active owner of this business." }, 403);

  let invitedUserId: string | null = null;
  let invitationSent = false;
  let existingAuthUser = null;
  for (let page = 1; page <= 10000; page += 1) {
    const { data: usersPage, error: usersError } = await admin.auth.admin.listUsers({ page, perPage: 1000 });
    if (usersError) return response({ error: "Could not verify whether this email already has an Auth account." }, 500);
    existingAuthUser = usersPage.users.find((user) => user.email?.toLowerCase() === email) || null;
    if (existingAuthUser || usersPage.users.length < 1000) break;
  }

  if (existingAuthUser) {
    invitedUserId = existingAuthUser.id;
    const { data: existingMembership, error: membershipCheckError } = await admin.from("business_memberships")
      .select("id").eq("business_id", businessId).eq("user_id", invitedUserId).maybeSingle();
    if (membershipCheckError) return response({ error: "Could not verify the existing membership." }, 500);
    if (existingMembership) return response({ error: "This user already has a membership in this business." }, 409);
  } else {
    const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { full_name: fullName },
    });
    if (inviteError || !invited.user) return response({ error: inviteError?.message || "Auth did not confirm the invitation." }, 400);
    invitedUserId = invited.user.id;
    invitationSent = true;
  }

  if (invitationSent) {
    const { error: profileError } = await admin.from("profiles").update({ full_name: fullName, phone }).eq("user_id", invitedUserId);
    if (profileError) return response({ error: "The invitation email was sent, but profile setup failed. Ask an administrator to finish staff setup." }, 500);
  }

  const { data: membershipId, error: insertError } = await admin.rpc("owner_add_invited_staff", {
    p_business_id: businessId,
    p_owner_user_id: authData.user.id,
    p_staff_user_id: invitedUserId,
  });
  if (insertError || !membershipId) return response({ error: invitationSent
    ? "The invitation email was sent, but business access was not created. Ask an administrator to complete setup."
    : "Business access could not be created." }, 500);

  return response({ membership_id: membershipId, invited_user_id: invitedUserId, invitation_sent: invitationSent });
});
