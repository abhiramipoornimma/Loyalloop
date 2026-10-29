import { supabase } from "../../supabase.js";

const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? "").replace(/[&<>"']/g, (char) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]));
const shell = $(".owner-shell");
const showError = (message) => {
  const box = document.createElement("div"); box.className = "owner-auth-message"; box.setAttribute("role", "status");
  box.innerHTML = `<h1>Business owner access</h1><p>${escapeHtml(message)}</p><a href="../../login.html">Return to Sign In</a>`;
  shell.replaceWith(box);
};

async function load() {
  const { data: { session } } = await supabase.auth.getSession();
  if (!session) { location.replace("/login.html"); return; }
  const { data: memberships, error: membershipError } = await supabase.from("business_memberships").select("id,business_id,created_at").eq("user_id", session.user.id).eq("role", "owner").eq("status", "active");
  if (membershipError) throw membershipError;
  if (!memberships?.length) { showError("Your signed-in account does not have an active business owner membership."); return; }
  if (memberships.length > 1) { showError("This dashboard currently supports one active owner business per account. Ask an administrator to confirm the intended business."); return; }
  const membership = memberships[0];
  const dashboardQueries = [
    supabase.from("businesses").select("id,slug,display_name,category,status").eq("id", membership.business_id).single(),
    supabase.from("business_details").select("business_id,contact_email,contact_phone").eq("business_id", membership.business_id).maybeSingle(),
    supabase.from("business_branding").select("business_id,logo_path,background_color,primary_color,secondary_color,text_color,theme_name,welcome_message,description").eq("business_id", membership.business_id).maybeSingle(),
    supabase.from("loyalty_programs").select("id,name,status").eq("business_id", membership.business_id).maybeSingle(),
    supabase.from("business_memberships").select("id,user_id,status,created_at").eq("business_id", membership.business_id).eq("role", "staff"),
    supabase.from("customer_loyalty_memberships").select("id,customer_user_id,status,enrolled_at").eq("business_id", membership.business_id),
    supabase.from("reward_redemptions").select("id,loyalty_membership_id,reward_rule_id,reward_name_snapshot,stamps_redeemed,redeemed_by,redeemed_at").eq("business_id", membership.business_id).order("redeemed_at", { ascending: false }),
    supabase.from("stamp_transactions").select("loyalty_membership_id,stamp_delta,created_at").eq("business_id", membership.business_id).order("created_at", { ascending: false }),
    supabase.from("reward_rules").select("id,reward_type").eq("business_id", membership.business_id),
  ];
  const dashboardQueryNames = ["business", "business details", "branding", "loyalty programme", "staff", "loyalty members", "redemptions", "stamp transactions", "reward rule history"];
  const [businessRes, detailsRes, brandRes, programRes, staffRes, customerRes, redemptionRes, ledgerRes, rewardRulesRes] = await Promise.all(dashboardQueries);
  const dashboardResults = [businessRes, detailsRes, brandRes, programRes, staffRes, customerRes, redemptionRes, ledgerRes, rewardRulesRes];
  const failedIndex = dashboardResults.findIndex((result) => result.error);
  if (failedIndex !== -1) {
    const error = dashboardResults[failedIndex].error;
    console.error(`Owner dashboard failed to load ${dashboardQueryNames[failedIndex]}.`, error);
    throw new Error(`Could not load ${dashboardQueryNames[failedIndex]}: ${error.message}`);
  }
  const business = businessRes.data, detail = detailsRes.data || {}, branding = brandRes.data || {}, program = programRes.data;
  const rulesRes = program ? await supabase.from("reward_rules").select("id,stamps_required,reward_name,description,reward_type,discount_percent,is_active,version,minimum_purchase,validity_days,valid_until").eq("program_id", program.id).eq("is_active", true).maybeSingle() : { data: null, error: null };
  if (rulesRes.error) {
    console.error("Owner dashboard failed to load reward rules.", rulesRes.error);
    throw new Error(`Could not load reward rules: ${rulesRes.error.message}`);
  }
  const rule = rulesRes.data;
  const staff = staffRes.data || [], customers = customerRes.data || [], redemptions = redemptionRes.data || [], ledger = ledgerRes.data || [], rewardRules = rewardRulesRes.data || [];
  const balances = new Map();
  for (const tx of ledger) balances.set(tx.loyalty_membership_id, (balances.get(tx.loyalty_membership_id) || 0) + tx.stamp_delta);
  const customerByMembership = new Map(customers.map((row) => [row.id, row]));
  const rewardRuleById = new Map(rewardRules.map((row) => [row.id, row]));
  const customerLastActivity = new Map(customers.map((row) => [row.id, row.enrolled_at]));
  for (const transaction of ledger) {
    const currentActivity = customerLastActivity.get(transaction.loyalty_membership_id);
    if (!currentActivity || transaction.created_at > currentActivity) {
      customerLastActivity.set(transaction.loyalty_membership_id, transaction.created_at);
    }
  }

  const businessName = business.display_name;
  document.querySelectorAll(".business-name-inline").forEach((node) => node.textContent = businessName);
  $("#sidebar-business-name").textContent = businessName; $("#heading-business-name").textContent = businessName;
  $("#topbar-business-name").textContent = businessName;
  $("#welcome-owner-name").textContent = session.user.email || "Owner"; $("#sidebar-owner-name").textContent = session.user.email || "Owner";
  const live = $(".live-status"); live.innerHTML = `<i></i> Business ${escapeHtml(business.status)}`;
  $("#owner-stats").innerHTML = [["Loyalty members", customers.length], ["Stamps issued", ledger.filter(x => x.stamp_delta > 0).reduce((n,x)=>n+x.stamp_delta,0)], ["Rewards redeemed", redemptions.length], ["Active staff", staff.filter(x=>x.status === "active").length]].map(([label,count])=>`<article class="owner-stat"><div class="owner-stat-top"><h3>${label}</h3></div><strong>${count}</strong><small>Supabase records visible to this business</small></article>`).join("");
  $("#overview-reward-name").textContent = rule?.reward_name || "No active reward rule";
  $("#overview-reward-description").textContent = rule?.description || "An owner can publish a rule through the existing reward workflow.";
  $("#overview-stamp-caption").textContent = rule ? `${rule.stamps_required} stamps required · active rule v${rule.version}` : "No active reward rule";
  $("#overview-stamps").innerHTML = rule ? Array.from({length: Math.min(rule.stamps_required, 20)},()=>'<span class="stamp-mark owner-stamp-mark"></span>').join("") : "";
  const dateFmt = value => value ? new Intl.DateTimeFormat("en", {dateStyle:"medium"}).format(new Date(value)) : "—";

  $("#staff-count").textContent = `${staff.length} staff members`;
  $("#staff-table").innerHTML = staff.map(row=>`<tr><td><div class="member-cell"><strong>Account ${escapeHtml(row.user_id.slice(0,8))}</strong><small>${escapeHtml(row.user_id)}</small></div></td><td>Restricted by profile RLS</td><td>Restricted by profile RLS</td><td>${escapeHtml(businessName)}</td><td>${escapeHtml(row.status)}</td><td>${dateFmt(row.created_at)}</td><td><button class="row-action" type="button" data-toggle-staff="${escapeHtml(row.id)}" data-next-status="${row.status==="active"?"inactive":"active"}">${row.status==="active"?"Deactivate":"Activate"}</button><button class="row-action" type="button" data-remove-staff="${escapeHtml(row.id)}">Remove</button></td></tr>`).join("");
  $("#staff-empty").hidden = staff.length > 0;
  const staffOperationFeedback = $("#staff-operation-feedback");
  async function updateStaffMembership(button, operation) {
    if (!confirm(operation === "remove" ? "Remove this staff membership from the business?" : "Change this staff membership status?")) return;
    staffOperationFeedback.textContent = operation === "remove" ? "Removing staff access…" : "Updating staff access…";
    try {
      const request = operation === "remove"
        ? supabase.from("business_memberships").delete().eq("id", button.dataset.removeStaff).eq("business_id", business.id).select("id")
        : supabase.from("business_memberships").update({ status: button.dataset.nextStatus }).eq("id", button.dataset.toggleStaff).eq("business_id", business.id).select("id");
      const { data, error } = await request;
      if (error) {
        console.error(`Owner could not ${operation} staff membership.`, error);
        staffOperationFeedback.textContent = `Staff access could not be ${operation === "remove" ? "removed" : "updated"}: ${error.message}`;
        return;
      }
      if (!data?.length) {
        staffOperationFeedback.textContent = "No staff membership was changed. Refresh and verify that the account is still assigned to this business.";
        return;
      }
      location.reload();
    } catch (error) {
      console.error(`Staff membership ${operation} request failed.`, error);
      staffOperationFeedback.textContent = `Staff access could not be ${operation === "remove" ? "removed" : "updated"}: ${error.message || "request failed"}`;
    }
  }
  $("#staff-table").querySelectorAll("[data-toggle-staff]").forEach(button=>button.addEventListener("click",()=>updateStaffMembership(button,"update")));
  $("#staff-table").querySelectorAll("[data-remove-staff]").forEach(button=>button.addEventListener("click",()=>updateStaffMembership(button,"remove")));

  function renderCustomers() {
    const query = $("#customer-search").value.trim().toLowerCase();
    const filter = $("#customer-filter").value;
    const now = Date.now();
    const filteredCustomers = customers.filter((row) => {
      const balance = balances.get(row.id) || 0;
      const lastActivity = customerLastActivity.get(row.id);
      const recent = lastActivity && now - new Date(lastActivity).getTime() <= 7 * 24 * 60 * 60 * 1000;
      const matchesFilter = filter === "All"
        || (filter === "Rewards" && row.status === "active" && rule?.stamps_required && balance >= rule.stamps_required)
        || (filter === "Recent" && row.status === "active" && recent);
      return matchesFilter && [row.customer_user_id, balance, row.status].some((value) => String(value).toLowerCase().includes(query));
    });
    $("#customer-count").textContent = `${filteredCustomers.length} of ${customers.length} loyalty members`;
    $("#customer-table").innerHTML = filteredCustomers.map(row=>{
      const balance = balances.get(row.id) || 0;
      const availableRewards = rule?.stamps_required ? Math.floor(Math.max(0,balance)/rule.stamps_required) : 0;
      const redemptionCount = redemptions.filter(item=>item.loyalty_membership_id===row.id).length;
      return `<tr><td><div class="member-cell"><strong>Account ${escapeHtml(row.customer_user_id.slice(0,8))}</strong><small>Customer identity details are restricted by profile RLS</small></div></td><td>${dateFmt(row.enrolled_at)}</td><td>${balance}</td><td>${availableRewards}</td><td>${redemptionCount}</td><td>${dateFmt(customerLastActivity.get(row.id))}</td><td>—</td></tr>`;
    }).join("");
    $("#customer-empty").hidden = filteredCustomers.length > 0;
  }

  for (const row of staff) {
    if (!row.user_id) continue;
    const option = document.createElement("option");
    option.value = row.user_id;
    option.textContent = `Account ${row.user_id.slice(0,8)}`;
    $("#redemption-staff").append(option);
  }
  const ownerOption = document.createElement("option");
  ownerOption.value = session.user.id;
  ownerOption.textContent = "Owner";
  $("#redemption-staff").append(ownerOption);

  function renderRedemptions() {
    const query = $("#redemption-search").value.trim().toLowerCase();
    const from = $("#redemption-from").value;
    const to = $("#redemption-to").value;
    const rewardType = $("#redemption-type").value;
    const staffId = $("#redemption-staff").value;
    const status = $("#redemption-status").value;
    const filteredRedemptions = redemptions.filter((row) => {
      const member = customerByMembership.get(row.loyalty_membership_id);
      const type = rewardRuleById.get(row.reward_rule_id)?.reward_type;
      const rewardDate = new Date(row.redeemed_at).toISOString().slice(0,10);
      const matchesType = rewardType === "All"
        || (rewardType === "free-item" && type === "free_item")
        || (rewardType === "discount" && type === "discount")
        || (rewardType === "custom" && type === "other");
      const matchesStatus = status === "All" || status === "Completed";
      return (!from || rewardDate >= from)
        && (!to || rewardDate <= to)
        && matchesType
        && (staffId === "All" || row.redeemed_by === staffId)
        && matchesStatus
        && [row.id, member?.customer_user_id, row.reward_name_snapshot, row.redeemed_by].some((value) => String(value || "").toLowerCase().includes(query));
    });
    $("#redemption-count").textContent = `${filteredRedemptions.length} of ${redemptions.length} records`;
    $("#redemption-table").innerHTML = filteredRedemptions.map(row=>{
      const member=customerByMembership.get(row.loyalty_membership_id);
      return `<tr><td><strong>${escapeHtml(row.id.slice(0,8))}</strong></td><td><div class="member-cell"><strong>Account ${escapeHtml(member?.customer_user_id.slice(0,8)||"unknown")}</strong><small>Identity details restricted</small></div></td><td>${escapeHtml(row.reward_name_snapshot)}</td><td>${row.stamps_redeemed}</td><td>${dateFmt(row.redeemed_at)}</td><td>${escapeHtml(row.redeemed_by?.slice(0,8)||"—")}</td><td>Completed</td><td>—</td></tr>`;
    }).join("");
    $("#redemption-empty").hidden = filteredRedemptions.length > 0;
  }
  renderCustomers();
  renderRedemptions();
  $("#recent-activity-list").innerHTML = redemptions.slice(0, 4).map(row=>`<div class="activity-row"><span class="activity-avatar">✓</span><span class="activity-copy"><strong>${escapeHtml(row.reward_name_snapshot)}</strong><small>Account ${escapeHtml(customerByMembership.get(row.loyalty_membership_id)?.customer_user_id.slice(0,8)||"unknown")} · ${escapeHtml(businessName)}</small></span><span class="activity-time">${dateFmt(row.redeemed_at)}</span></div>`).join("") || "<p class=\"empty-row\">No loyalty activity has been recorded yet.</p>";
  const weekStart = Date.now() - 7 * 24 * 60 * 60 * 1000;
  const redemptionCountsByReward = new Map();
  for (const redemption of redemptions) {
    redemptionCountsByReward.set(redemption.reward_name_snapshot, (redemptionCountsByReward.get(redemption.reward_name_snapshot) || 0) + 1);
  }
  const mostRedeemed = [...redemptionCountsByReward.entries()].sort((a,b)=>b[1]-a[1])[0];
  $("#redemption-stats").innerHTML = [["Total redemptions",redemptions.length,"Recorded transactions"],["Today",redemptions.filter(x=>new Date(x.redeemed_at).toDateString()===new Date().toDateString()).length,"Today"],["This week",redemptions.filter(x=>new Date(x.redeemed_at).getTime()>=weekStart).length,"Last 7 days"],["Most redeemed",mostRedeemed?.[0]||"—",mostRedeemed?`${mostRedeemed[1]} redemptions`:"No reward history"]].map(([label,value,hint])=>`<article class="redemption-stat"><span>${label}</span><strong>${escapeHtml(value)}</strong><span class="stat-hint">${hint}</span></article>`).join("");
  const settings = $("#settings-form").elements; settings.displayName.value=business.display_name; settings.email.value=detail.contact_email||""; settings.phone.value=detail.contact_phone||""; settings.slug.value=business.slug; settings.active.checked=program?.status==="active";
  const brandForm = $("#branding-form").elements; brandForm.displayName.value=business.display_name; brandForm.background.value=branding.background_color||"#F8F6F0"; brandForm.primary.value=branding.primary_color||"#879780"; brandForm.secondary.value=branding.secondary_color||"#EDE6D7"; brandForm.text.value=branding.text_color||"#292D28"; brandForm.theme.value=branding.theme_name||"Sage & Cream"; brandForm.welcome.value=branding.welcome_message||""; brandForm.description.value=branding.description||"";
  if(branding.logo_path){const {data}=await supabase.storage.from("business-logos").createSignedUrl(branding.logo_path,3600);if(data?.signedUrl){$("#preview-uploaded-logo").src=data.signedUrl;$("#preview-uploaded-logo").hidden=false;$("#preview-logo-fallback").hidden=true;}}
  $("#logo-upload").addEventListener("change",event=>{const file=event.target.files?.[0];if(!file)return;if(!["image/png","image/jpeg","image/webp"].includes(file.type)||file.size>2097152){$("#branding-feedback").textContent="Choose a PNG, JPEG, or WebP image up to 2 MB.";event.target.value="";return;}const reader=new FileReader();reader.onload=()=>{$("#preview-uploaded-logo").src=reader.result;$("#preview-uploaded-logo").hidden=false;$("#preview-logo-fallback").hidden=true;};reader.readAsDataURL(file);});
  const ruleForm=$("#rules-form").elements; if(rule){ruleForm.stamps.value=rule.stamps_required;ruleForm.rewardName.value=rule.reward_name;ruleForm.rewardDescription.value=rule.description||"";ruleForm.type.value=rule.reward_type.replace("_","-");ruleForm.discount.value=rule.discount_percent||"";ruleForm.minimum.value=rule.minimum_purchase??"";ruleForm.validity.value=rule.validity_days??"";ruleForm.active.checked=program?.status==="active";} else ruleForm.active.checked=false;
  $("#open-public-preview").href=`../../b/?slug=${encodeURIComponent(business.slug)}`; $("#top-public-preview").href=$("#open-public-preview").href;
  document.querySelectorAll("[data-close-owner-dialog]").forEach(button=>button.addEventListener("click",()=>button.closest("dialog").close()));
  $("#staff-form").addEventListener("submit",async event=>{
    event.preventDefault();
    const form=event.currentTarget, f=form.elements, button=form.querySelector("button[type='submit']");
    if(!form.reportValidity())return;
    button.disabled=true;
    $("#staff-feedback").textContent="Sending the staff invitation…";
    try{
      const {data,error}=await supabase.functions.invoke("invite-business-staff",{body:{business_id:business.id,full_name:f.name.value.trim(),email:f.email.value.trim(),phone:f.phone.value.trim()||null}});
      if(error||!data?.membership_id){
        const message=error?.message||data?.error||"The invitation was not confirmed. No success was reported.";
        console.error("Owner staff invitation failed.",error||data);
        $("#staff-feedback").textContent=`Staff access could not be created: ${message}`;
        return;
      }
      $("#staff-feedback").textContent=data.invitation_sent?"Invitation email sent and business access created.":"Existing LoyalLoop account added to this business as staff.";
      form.reset();
      setTimeout(()=>location.reload(),900);
    }catch(error){
      console.error("Owner staff invitation request failed.",error);
      $("#staff-feedback").textContent=`Staff access could not be created: ${error.message||"invitation service unavailable"}`;
    }finally{button.disabled=false;}
  });
  $("#branding-form").addEventListener("submit",async event=>{event.preventDefault();const form=event.currentTarget,f=form.elements,button=form.querySelector("button[type='submit']");let logoPath=branding.logo_path||null;const file=f.logo?.files?.[0];if(file){if(!["image/png","image/jpeg","image/webp"].includes(file.type)||file.size>2097152){$("#branding-feedback").textContent="Choose a PNG, JPEG, or WebP image up to 2 MB.";return;}const safeName=file.name.toLowerCase().replace(/[^a-z0-9.-]/g,"-");logoPath=`${business.id}/${Date.now()}-${safeName}`;const upload=await supabase.storage.from("business-logos").upload(logoPath,file,{contentType:file.type,upsert:false});if(upload.error){console.error("Owner logo upload failed.",upload.error);$("#branding-feedback").textContent=`Logo upload failed: ${upload.error.message}`;return;}}button.disabled=true;try{const {error}=await supabase.rpc("owner_save_business_branding",{p_business_id:business.id,p_display_name:f.displayName.value.trim(),p_logo_path:logoPath,p_background_color:f.background.value,p_primary_color:f.primary.value,p_secondary_color:f.secondary.value,p_text_color:f.text.value,p_theme_name:f.theme.value,p_welcome_message:f.welcome.value.trim()||null,p_description:f.description.value.trim()||null});if(error){console.error("Owner branding save failed.",error);$("#branding-feedback").textContent=`Branding could not be saved: ${error.message}`;return;}$("#branding-feedback").textContent="Branding saved.";setTimeout(()=>location.reload(),500);}catch(error){console.error("Owner branding save request failed.",error);$("#branding-feedback").textContent=`Branding could not be saved: ${error.message||"the authorized workflow was unavailable."}`;}finally{button.disabled=false;}});
  $("#rules-form").addEventListener("submit",async event=>{
    event.preventDefault();
    const form=event.currentTarget,f=form.elements,button=form.querySelector("button[type='submit']"),type=f.type.value==="custom"?"other":f.type.value.replace("-","_");
    if(!form.reportValidity())return;
    button.disabled=true;
    $("#rules-feedback").textContent="Saving reward rule…";
    try{
      const {data,error}=await supabase.rpc("publish_reward_rule_with_terms",{p_business_id:business.id,p_stamps_required:Number(f.stamps.value),p_reward_name:f.rewardName.value.trim(),p_description:f.rewardDescription.value.trim()||null,p_reward_type:type,p_discount_percent:type==="discount"?Number(f.discount.value):null,p_minimum_purchase:f.minimum.value?Number(f.minimum.value):null,p_validity_days:f.validity.value?Number(f.validity.value):null,p_program_active:f.active.checked});
      if(error||!data){
        console.error("Owner reward rule save failed.",error||data);
        $("#rules-feedback").textContent=`Reward rule could not be saved: ${error?.message||"the server did not confirm the save"}`;
        return;
      }
      $("#rules-feedback").textContent="Reward rule and programme status saved.";
      setTimeout(()=>location.reload(),500);
    }catch(error){
      console.error("Owner reward rule save request failed.",error);
      $("#rules-feedback").textContent=`Reward rule could not be saved: ${error.message||"the authorized workflow was unavailable"}`;
    }finally{button.disabled=false;}
  });
  $("#settings-form").addEventListener("submit",async event=>{
    event.preventDefault();
    const form=event.currentTarget,f=form.elements,button=form.querySelector("button[type='submit']");
    if(!form.reportValidity())return;
    button.disabled=true;
    $("#settings-feedback").textContent="Saving business settings…";
    try{
      const {data:status,error}=await supabase.rpc("owner_save_business_settings",{p_business_id:business.id,p_display_name:f.displayName.value.trim(),p_slug:f.slug.value.trim(),p_contact_email:f.email.value.trim(),p_contact_phone:f.phone.value.trim()||null,p_program_status:f.active.checked?"active":"paused"});
      if(error||!status){
        console.error("Owner business settings save failed.",error||status);
        $("#settings-feedback").textContent=`Business settings could not be saved: ${error?.message||"the server did not confirm the save"}`;
        return;
      }
      $("#settings-feedback").textContent=`Business details and programme status (${status}) saved.`;
      setTimeout(()=>location.reload(),500);
    }catch(error){
      console.error("Owner business settings save request failed.",error);
      $("#settings-feedback").textContent=`Business settings could not be saved: ${error.message||"the authorized workflow was unavailable"}`;
    }finally{button.disabled=false;}
  });
  $("#add-staff").addEventListener("click",()=>$("#staff-dialog").showModal());
  $("#settings-reset").addEventListener("click",()=>location.reload());
  $("#owner-data-note").innerHTML="<span class=\"demo-indicator\"></span><div><strong>Authorized business data</strong><span>Records are loaded under your active owner membership and current Supabase policies.</span></div>";
  $("#staff-search").addEventListener("input",()=>{const query=$("#staff-search").value.trim().toLowerCase();$("#staff-table").querySelectorAll("tr").forEach(row=>row.hidden=!row.textContent.toLowerCase().includes(query));});
  $("#redemption-search").addEventListener("input",renderRedemptions);
  ["#redemption-from","#redemption-to","#redemption-type","#redemption-staff","#redemption-status"].forEach(selector=>$(selector).addEventListener("change",renderRedemptions));
  $("#customer-search").addEventListener("input",renderCustomers);
  $("#customer-filter").addEventListener("change",renderCustomers);
  document.querySelectorAll("[data-owner-signout]").forEach(link=>link.addEventListener("click",async event=>{event.preventDefault();await supabase.auth.signOut();location.assign("/login.html");}));
  shell.hidden=false;
}

load().catch(error=>showError(error?.message?.includes("JWT")?"Your session could not be verified. Please sign in again.":error?.message||"Dashboard records could not be loaded. Check the Supabase connection and RLS policies."));
