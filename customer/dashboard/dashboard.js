import { supabase } from "../../supabase.js";

const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[char]);
const empty = $("#membership-empty");
const grid = $("#membership-grid");
const enrolForm = $("#enrol-form");
const enrolMessage = $("#enrol-message");
const enrolSlug = $("#enrol-slug");

function setEnrolMessage(text, success = false) {
  enrolMessage.textContent = text;
  enrolMessage.style.color = success ? "#566B55" : "";
}

async function start() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) { location.replace("/login.html"); return; }
  const user = session.user;
  const [{ data: profile, error: profileError }, { data: customerProfile, error: customerProfileError }, { data: memberships, error: membershipsError }] = await Promise.all([
    supabase.from("profiles").select("full_name").eq("user_id", user.id).maybeSingle(),
    supabase.from("customer_profiles").select("user_id").eq("user_id", user.id).maybeSingle(),
    supabase.from("customer_loyalty_memberships").select("id,business_id,program_id,status,enrolled_at").eq("customer_user_id", user.id),
  ]);
  if (profileError || customerProfileError || membershipsError) throw new Error("Your account or loyalty memberships could not be loaded. Check the applied migrations and RLS policies.");
  if (!customerProfile) {
    $("#customer-demo-banner").textContent = "Your customer profile is not ready yet. Please sign in again or contact support.";
    return;
  }

  const name = profile?.full_name || user.email || "Member";
  $("#customer-greeting").textContent = name.split(" ")[0];
  $("#account-name").textContent = name;
  $("#account-description").textContent = user.email || "Signed-in LoyalLoop account";
  $("#account-avatar").textContent = name.charAt(0).toUpperCase();
  $("#account-header-name").textContent = name;

  const ids = memberships || [];
  if (!ids.length) { grid.hidden = true; empty.hidden = false; }
  else {
    const businessIds = [...new Set(ids.map((row) => row.business_id))];
    const programIds = [...new Set(ids.map((row) => row.program_id))];
    const [businessResult, brandingResult, programResult, ruleResult, offerResult, ledgerResult, redemptionResult] = await Promise.all([
      supabase.from("businesses").select("id,slug,display_name,status,category").in("id", businessIds),
      supabase.from("business_branding").select("business_id,logo_path,background_color,primary_color,secondary_color,text_color,theme_name,welcome_message,description").in("business_id", businessIds),
      supabase.from("loyalty_programs").select("id,name,status").in("id", programIds),
      supabase.from("reward_rules").select("business_id,program_id,stamps_required,reward_name,is_active").in("program_id", programIds).eq("is_active", true),
      supabase.from("business_offers").select("business_id,starts_at,ends_at,status,is_public").in("business_id", businessIds).eq("status", "active").eq("is_public", true),
      supabase.from("stamp_transactions").select("business_id,loyalty_membership_id,stamp_delta,created_at").in("loyalty_membership_id", ids.map((row) => row.id)),
      supabase.from("reward_redemptions").select("business_id,loyalty_membership_id,id").in("loyalty_membership_id", ids.map((row) => row.id)),
    ]);
    const failed = [businessResult, brandingResult, programResult, ruleResult, offerResult, ledgerResult, redemptionResult].find((r) => r.error);
    if (failed) throw new Error("Some loyalty details are not available under your current database policies.");

    const byId = (rows, key) => new Map((rows || []).map((row) => [row[key], row]));
    const businesses = byId(businessResult.data, "id");
    const branding = byId(brandingResult.data, "business_id");
    const programs = byId(programResult.data, "id");
    const rules = byId(ruleResult.data, "program_id");
    const balances = new Map();
    const lastActivity = new Map();
    for (const tx of ledgerResult.data || []) {
      balances.set(tx.loyalty_membership_id, (balances.get(tx.loyalty_membership_id) || 0) + tx.stamp_delta);
      const previous = lastActivity.get(tx.loyalty_membership_id);
      if (!previous || tx.created_at > previous) lastActivity.set(tx.loyalty_membership_id, tx.created_at);
    }
    const offerCounts = new Map();
    const now = Date.now();
    for (const offer of offerResult.data || []) if ((!offer.starts_at || Date.parse(offer.starts_at) <= now) && (!offer.ends_at || Date.parse(offer.ends_at) >= now)) offerCounts.set(offer.business_id, (offerCounts.get(offer.business_id) || 0) + 1);
    const redemptionCounts = new Map();
    for (const item of redemptionResult.data || []) redemptionCounts.set(item.loyalty_membership_id, (redemptionCounts.get(item.loyalty_membership_id) || 0) + 1);
    const logoUrls = new Map();
    await Promise.all((brandingResult.data || []).filter(row => row.logo_path).map(async row => {
      const { data } = await supabase.storage.from("business-logos").createSignedUrl(row.logo_path, 3600);
      if (data?.signedUrl) logoUrls.set(row.business_id, data.signedUrl);
    }));

    const cards = ids.map((membership) => {
      const business = businesses.get(membership.business_id);
      const program = programs.get(membership.program_id);
      if (!business || !program) return "";
      const brand = branding.get(business.id) || {};
      const rule = rules.get(program.id);
      const stampsRequired = rule?.stamps_required || 0;
      const stamps = Math.max(0, balances.get(membership.id) || 0);
      const progress = stampsRequired ? Math.min(stamps % stampsRequired, stampsRequired) : 0;
      const rewards = stampsRequired ? Math.floor(stamps / stampsRequired) : 0;
      const bg = /^#[\da-f]{6}$/i.test(brand.background_color || "") ? brand.background_color : "#F8F6F0";
      const primary = /^#[\da-f]{6}$/i.test(brand.primary_color || "") ? brand.primary_color : "#879780";
      const secondary = /^#[\da-f]{6}$/i.test(brand.secondary_color || "") ? brand.secondary_color : "#EDE6D7";
      const textColor = /^#[\da-f]{6}$/i.test(brand.text_color || "") ? brand.text_color : "#292D28";
      const activeOffers = offerCounts.get(business.id) || 0;
      const programActive = program.status === "active" && business.status === "active";
      const logo = logoUrls.get(business.id) || "";
      return `<article class="membership-card" style="--business-background:${bg};--business-primary:${primary};--business-secondary:${secondary};--business-text:${textColor};--business-ink:#566B55"><div class="membership-card-banner"><span class="membership-logo">${logo ? `<img src="${escapeHtml(logo)}" alt="" />` : "LL"}</span><span class="membership-heading-copy"><small>${escapeHtml(brand.theme_name || business.category || "Loyalty membership")}</small><h3>${escapeHtml(business.display_name)}</h3></span><span class="membership-active"><i></i>${programActive ? "Active membership" : "Programme paused"}</span></div><div class="membership-card-body"><p class="membership-description">${escapeHtml(brand.description || brand.welcome_message || "")}</p><div class="membership-progress-row"><span>Loyalty card progress</span><strong>${stamps} / ${stampsRequired || "—"} stamps</strong></div><div class="membership-progress-track" role="progressbar" aria-label="${escapeHtml(business.display_name)} stamp progress" aria-valuenow="${progress}" aria-valuemin="0" aria-valuemax="${stampsRequired || 1}"><span style="width:${stampsRequired ? (rewards ? 100 : progress / stampsRequired * 100) : 0}%"></span></div><div class="membership-reward-row"><span class="membership-reward-copy"><small>NEXT REWARD</small><strong>${escapeHtml(rule?.reward_name || "No active reward rule")}</strong></span><span class="membership-reward-count ${rewards ? "available" : ""}">${rewards ? `${rewards} reward${rewards === 1 ? "" : "s"} ready` : stampsRequired ? `${stampsRequired - progress} to go` : ""}</span></div><div class="membership-card-bottom"><span>${activeOffers ? `${activeOffers} active offer${activeOffers === 1 ? "" : "s"}` : "No active offers"}</span><a class="membership-view-link" href="/customer/business/${encodeURIComponent(business.slug)}">View Loyalty Card <span aria-hidden="true">→</span></a></div><small>Joined ${new Intl.DateTimeFormat("en", { dateStyle: "medium" }).format(new Date(membership.enrolled_at))}</small></article>`;
    }).filter(Boolean);
    grid.innerHTML = cards.join("");
    grid.hidden = !cards.length;
    empty.hidden = cards.length > 0;
  }

  enrolForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const slug = enrolSlug.value.trim().toLowerCase();
    if (!slug) return;
    enrolMessage.textContent = "";
    enrolSlug.disabled = true;
    const submitButton = enrolForm.querySelector("button[type='submit']");
    submitButton.disabled = true;
    submitButton.textContent = "Joining…";
    try {
      const { data: business, error: businessError } = await supabase.from("businesses").select("id,slug,display_name,status").eq("slug", slug).eq("status", "active").maybeSingle();
      if (businessError || !business) {
        setEnrolMessage("No active business found with that slug.");
        return;
      }
      const idempotencyKey = `enrol:${user.id}:${business.id}:${crypto.randomUUID()}`;
      const { error } = await supabase.rpc("enroll_customer", {
        p_business_id: business.id,
        p_customer_user_id: null,
        p_idempotency_key: idempotencyKey,
      });
      if (error) {
        const msg = String(error.message || "").toLowerCase();
        if (msg.includes("already") || msg.includes("conflict") || msg.includes("exists")) {
          setEnrolMessage("You are already a member of this business.", false);
        } else if (msg.includes("not active and approved") || msg.includes("no active loyalty program")) {
          setEnrolMessage("This business is not ready for members yet.", false);
        } else if (msg.includes("authentication")) {
          setEnrolMessage("Please sign in again and try joining.", false);
        } else {
          setEnrolMessage("Could not join this business. Please try again.", false);
        }
        return;
      }
      setEnrolMessage(`Joined ${escapeHtml(business.display_name)}. Your loyalty card is ready.`, true);
      enrolForm.reset();
      setTimeout(() => location.reload(), 800);
    } catch {
      setEnrolMessage("Could not reach LoyalLoop. Check your connection and try again.", false);
    } finally {
      enrolSlug.disabled = false;
      submitButton.disabled = false;
      submitButton.textContent = "Join";
    }
  });
}

document.querySelectorAll("[data-demo-logout]").forEach((link) => link.addEventListener("click", async (event) => {
  event.preventDefault();
  const { error } = await supabase.auth.signOut();
  if (!error) location.assign("/login.html");
}));

start().catch((error) => {
  $("#customer-demo-banner").textContent = error.message || "Your dashboard could not be loaded.";
  grid.hidden = true;
  empty.hidden = false;
  empty.querySelector("p").textContent = "Please check your connection and try again.";
});
