import { supabase } from "../supabase.js";

const $ = selector => document.querySelector(selector);
const safeColor = (value, fallback) => typeof value === "string" && /^#[\da-f]{6}$/i.test(value) ? value : fallback;
const slug = new URLSearchParams(location.search).get("slug") || "";
const card = $("#public-business-card");
const status = $("#public-programme-status");

function showUnavailable(message) {
  card.hidden = true;
  status.textContent = message;
  document.title = "Business page unavailable | LoyalLoop";
}

async function load() {
  if (!slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) { showUnavailable("This business page could not be found."); return; }
  const { data: business, error } = await supabase.from("businesses").select("id,slug,display_name,category,status").eq("slug", slug).eq("status", "active").maybeSingle();
  if (error || !business) { showUnavailable("This business page is not currently available."); return; }
  const [brandingResult, programResult] = await Promise.all([
    supabase.from("business_branding").select("logo_path,background_color,primary_color,secondary_color,text_color,theme_name,welcome_message,description").eq("business_id", business.id).maybeSingle(),
    supabase.from("loyalty_programs").select("id,status").eq("business_id", business.id).maybeSingle(),
  ]);
  if (brandingResult.error || programResult.error) { showUnavailable("Business details are temporarily unavailable."); return; }
  const branding = brandingResult.data || {};
  const program = programResult.data;
  const ruleResult = program?.status === "active"
    ? await supabase.from("reward_rules").select("stamps_required,reward_name,description,is_active,minimum_purchase,validity_days,valid_until").eq("program_id", program.id).eq("is_active", true).maybeSingle()
    : { data: null, error: null };
  if (ruleResult.error) { showUnavailable("Loyalty programme details are temporarily unavailable."); return; }
  const rule = ruleResult.data;
  card.style.setProperty("--public-bg", safeColor(branding.background_color, "#F8F6F0"));
  card.style.setProperty("--public-primary", safeColor(branding.primary_color, "#879780"));
  card.style.setProperty("--public-secondary", safeColor(branding.secondary_color, "#EDE6D7"));
  card.style.setProperty("--public-text", safeColor(branding.text_color, "#292D28"));
  $("#public-business-name").textContent = business.display_name;
  $("#public-card-business").textContent = business.display_name;
  $("#public-theme-name").textContent = branding.theme_name || business.category || "LOYALLOOP BUSINESS";
  $("#public-welcome").textContent = branding.welcome_message || "";
  $("#public-description").textContent = branding.description || "";
  document.title = `${business.display_name} | LoyalLoop`;
  const fallback = $("#public-logo-fallback"); fallback.textContent = business.display_name.charAt(0).toUpperCase();
  if (branding.logo_path) {
    const { data } = await supabase.storage.from("business-logos").createSignedUrl(branding.logo_path, 3600);
    if (data?.signedUrl) { $("#public-logo-image").src = data.signedUrl; $("#public-logo-image").hidden = false; fallback.hidden = true; }
  }
  if (rule) {
    $("#public-reward-name").textContent = rule.reward_name;
    $("#public-reward-description").textContent = rule.description || "";
    $("#public-progress-label").textContent = `Join this programme and collect ${rule.stamps_required} stamps to earn this reward.`;
    const count = Math.min(20, rule.stamps_required);
    $("#public-stamps").innerHTML = Array.from({length: count},(_,i)=>`<span class="public-stamp" aria-label="Stamp ${i+1}, not yet earned"></span>`).join("");
    status.textContent = "Loyalty programme active";
  } else {
    $("#public-reward-name").textContent = "No active reward";
    $("#public-reward-description").textContent = "This business has not published a reward rule yet.";
    $("#public-progress-label").textContent = "The loyalty programme is not currently active.";
    $("#public-stamps").replaceChildren();
    status.textContent = "Programme unavailable";
  }
  $(".public-demo-note").textContent = "Business information and reward rules";
  card.hidden = false;
}

load().catch(() => showUnavailable("This business page could not be loaded. Please try again later."));
