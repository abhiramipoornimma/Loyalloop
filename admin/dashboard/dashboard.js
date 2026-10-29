import { supabase } from "../../supabase.js";

const businesses = [];
const users = [];
const requests = [];
const $ = (selector) => document.querySelector(selector);
let activeRequestId = null;
let applicationsLoadError = false;

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

function formatDate(value) {
  if (!value) return "—";
  const date = value.length === 10 ? new Date(`${value}T00:00:00`) : new Date(value);
  return Number.isNaN(date.valueOf()) ? "—" : new Intl.DateTimeFormat("en", { day: "numeric", month: "short", year: "numeric" }).format(date);
}

function setFeedback(element, text, success = false) {
  element.textContent = text;
  element.style.color = success ? "#566B55" : "";
}

function replaceRows(target, rows) {
  target.splice(0, target.length, ...rows);
}

function titleCase(value) {
  return String(value || "").replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

async function loadAdminData() {
  const queries = [
    ["businesses", supabase.from("businesses").select("id, slug, display_name, category, status")],
    ["business details", supabase.from("business_details").select("business_id, contact_email, contact_phone, approval_status")],
    ["business memberships", supabase.from("business_memberships").select("id, business_id, user_id, role, status, created_at")],
    ["platform admins", supabase.from("platform_admins").select("user_id, is_active, created_at")],
    ["business applications", supabase.from("business_applications").select("id, business_id, owner_full_name, business_name, business_email, contact_phone, category, description, status, submitted_at").in("status", ["pending", "reviewed", "approved"]).order("submitted_at", { ascending: false })],
  ];
  const results = await Promise.all(queries.map(async ([name, query]) => {
    try {
      const result = await query;
      if (result.error) {
        console.error(`LoyalLoop admin query failed (${name}).`, result.error);
        return { data: [], error: result.error };
      }
      return { data: result.data || [], error: null };
    } catch (error) {
      console.error(`LoyalLoop admin query failed (${name}).`, error);
      return { data: [], error };
    }
  }));
  const [businessResult, detailsResult, membershipsResult, adminsResult, applicationsResult] = results;
  applicationsLoadError = Boolean(applicationsResult.error);

  const detailsByBusiness = new Map((detailsResult.data || []).map((item) => [item.business_id, item]));
  const applicationsByBusiness = new Map((applicationsResult.data || []).filter((item) => item.business_id).map((item) => [item.business_id, item]));

  replaceRows(businesses, (businessResult.data || []).map((item) => {
    const detail = detailsByBusiness.get(item.id);
    const application = applicationsByBusiness.get(item.id);
    return {
      id: item.id,
      name: item.display_name,
      slug: item.slug,
      category: item.category || "—",
      owner: application?.owner_full_name || "Owner name restricted by current profile RLS",
      email: detail?.contact_email || "—",
      status: titleCase(item.status),
      rawStatus: item.status,
      plan: "Not configured",
      startDate: null,
      endDate: null,
    };
  }));

  const businessNames = new Map(businesses.map((item) => [item.id, item.name]));
  const memberRows = (membershipsResult.data || []).map((item) => ({
    id: item.id,
    userId: item.user_id,
    name: `Account ${item.user_id.slice(0, 8)}`,
    email: "Not exposed by current profile RLS",
    phone: "Not exposed by current profile RLS",
    role: item.role === "owner" ? "Business Owner" : titleCase(item.role),
    business: businessNames.get(item.business_id) || item.business_id,
    status: titleCase(item.status),
    registered: item.created_at,
  }));
  const adminRows = (adminsResult.data || []).map((item) => ({
    id: item.user_id,
    userId: item.user_id,
    name: `Account ${item.user_id.slice(0, 8)}`,
    email: "Not exposed by current profile RLS",
    phone: "Not exposed by current profile RLS",
    role: "Platform Admin",
    business: "—",
    status: item.is_active ? "Active" : "Inactive",
    registered: item.created_at,
  }));
  replaceRows(users, [...adminRows, ...memberRows]);

  replaceRows(requests, (applicationsResult.data || []).map((item) => ({
    id: item.id,
    name: item.owner_full_name,
    email: item.business_email,
    phone: item.contact_phone,
    category: item.category,
    type: "Business application",
    subject: item.business_name,
    date: item.submitted_at,
    status: titleCase(item.status),
    rawStatus: item.status,
    businessId: item.business_id,
    message: item.description || "No description supplied.",
  })));

  const note = $("#dashboard-data-note");
  if (note) {
    const unavailable = queries.filter((_, index) => results[index].error).map(([name]) => name);
    note.textContent = unavailable.length
      ? `Some dashboard data could not be loaded: ${unavailable.join(", ")}. See the browser console for the corresponding Supabase error. Other available sections remain usable.`
      : "Business applications and dashboard records are loaded from Supabase. Accepting an application creates its business and grants owner access to the confirmed applicant.";
  }
}

function renderSummary() {
  const active = businesses.filter((business) => business.rawStatus === "active").length;
  const paused = businesses.filter((business) => business.rawStatus === "paused").length;
  const awaiting = applicationsLoadError ? "—" : requests.filter((request) => request.rawStatus === "pending").length;
  const metrics = [
    ["Total businesses", businesses.length, "Supabase business records", "▤"],
    ["Active businesses", active, "Currently enabled", "◉"],
    ["Paused businesses", paused, "Retained records", "Ⅱ"],
    ["New requests", awaiting, "Awaiting admin review", "✉"],
  ];
  $("#summary-grid").innerHTML = metrics.map(([label, value, hint, icon]) => `<article class="summary-card"><div class="summary-top"><h3>${label}</h3><span class="summary-icon" aria-hidden="true">${icon}</span></div><strong>${value}</strong><small>${hint}</small></article>`).join("");
  $("#nav-request-count").textContent = applicationsLoadError ? "!" : awaiting;
}

async function changeBusinessStatus(id, nextStatus) {
  const business = businesses.find((item) => item.id === id);
  if (!business || !["active", "paused"].includes(nextStatus)) return;
  if (!window.confirm(`${titleCase(nextStatus)} ${business.name}?`)) return;
  const { error } = await supabase.rpc("admin_set_business_status", { p_business_id: id, p_status: nextStatus });
  if (error) {
    window.alert("Business status could not be changed. The server authorization check rejected or could not complete this request.");
    return;
  }
  await loadAdminData();
  renderAll();
}

function renderBusinesses() {
  const query = $("#business-search").value.trim().toLowerCase();
  const filtered = businesses.filter((business) => [business.name, business.slug, business.category, business.owner, business.email].some((value) => value.toLowerCase().includes(query)));
  $("#business-count").textContent = `${filtered.length} ${filtered.length === 1 ? "business" : "businesses"}`;
  $("#business-table").innerHTML = filtered.map((business) => `<tr>
    <td><div class="business-cell"><strong>${escapeHtml(business.name)}</strong><small>${escapeHtml(business.slug)}</small></div></td>
    <td>${escapeHtml(business.category)}</td><td title="${escapeHtml(business.email)}">${escapeHtml(business.owner)}</td>
    <td><span class="status-pill ${business.rawStatus === "paused" ? "paused" : business.rawStatus === "pending" ? "pending" : ""}">${escapeHtml(business.status)}</span></td>
    <td>${["active", "paused"].includes(business.rawStatus) ? `<button class="table-action" type="button" data-toggle-business="${escapeHtml(business.id)}">${business.rawStatus === "active" ? "Pause" : "Resume"}</button>` : "—"}</td>
  </tr>`).join("");
  $("#business-empty").hidden = filtered.length > 0;
  $("#business-table").querySelectorAll("[data-toggle-business]").forEach((button) => button.addEventListener("click", () => {
    const business = businesses.find((item) => item.id === button.dataset.toggleBusiness);
    changeBusinessStatus(business.id, business.rawStatus === "active" ? "paused" : "active").catch(() => window.alert("Business status could not be changed."));
  }));
}

function renderUsers() {
  const role = $("#user-role").value;
  const query = $("#user-search").value.trim().toLowerCase();
  const filtered = users.filter((user) => (role === "All" || user.role === role) && [user.name, user.userId, user.email, user.phone, user.role, user.business, user.status].some((value) => value.toLowerCase().includes(query)));
  $("#user-table-title").textContent = ({ "Business Owner": "Business Owners", Staff: "Staff", Customer: "Customers", "Platform Admin": "Platform Admins", All: "Accounts" })[role];
  $("#user-count").textContent = `${filtered.length} ${filtered.length === 1 ? "account" : "accounts"}`;
  $("#user-table").innerHTML = filtered.map((user) => `<tr>
    <td><button class="text-action" type="button" data-user-details="${escapeHtml(user.id)}">${escapeHtml(user.name)}</button></td><td>${escapeHtml(user.email)}</td><td>${escapeHtml(user.phone)}</td>
    <td>${escapeHtml(user.role)}</td><td>${escapeHtml(user.business)}</td><td><span class="status-pill ${user.status === "Inactive" ? "inactive" : ""}">${escapeHtml(user.status)}</span></td><td>${formatDate(user.registered)}</td>
  </tr>`).join("");
  $("#user-empty").textContent = role === "Customer"
    ? "Customer profiles are not exposed to platform admins by the current RLS policy."
    : "No account memberships match your search.";
  $("#user-empty").hidden = filtered.length > 0;
  $("#user-table").querySelectorAll("[data-user-details]").forEach((button) => button.addEventListener("click", () => showUser(button.dataset.userDetails)));
}

function showUser(id) {
  const user = users.find((item) => item.id === id);
  if (!user) return;
  const details = [["Account ID", user.userId], ["Email", user.email], ["Phone", user.phone], ["Role", user.role], ["Business", user.business], ["Account status", user.status], ["Membership created", formatDate(user.registered)]];
  $("#user-detail-list").innerHTML = details.map(([label, value]) => `<div><dt>${label}</dt><dd>${escapeHtml(value)}</dd></div>`).join("");
  $("#user-dialog").showModal();
}

function renderRequests() {
  const query = $("#request-search").value.trim().toLowerCase();
  const filtered = requests.filter((request) => [request.id, request.name, request.email, request.type, request.subject, request.status].some((value) => value.toLowerCase().includes(query)));
  $("#request-count").textContent = applicationsLoadError ? "Unavailable" : `${filtered.length} ${filtered.length === 1 ? "application" : "applications"}`;
  $("#request-table").innerHTML = filtered.map((request) => `<tr>
    <td><strong>${escapeHtml(request.id.slice(0, 8))}</strong></td><td>${escapeHtml(request.name)}</td><td>${escapeHtml(request.type)}</td><td>${escapeHtml(request.subject)}</td><td>${formatDate(request.date)}</td>
    <td><span class="status-pill ${request.rawStatus === "pending" ? "pending" : request.rawStatus === "rejected" ? "inactive" : "resolved"}">${escapeHtml(request.status)}</span></td>
    <td><button class="table-action" type="button" data-request-details="${escapeHtml(request.id)}">${request.rawStatus === "pending" ? "Review" : "Details"}</button></td>
  </tr>`).join("");
  $("#request-empty").textContent = applicationsLoadError
    ? "Business applications could not be loaded. Check the browser console for the Supabase query error."
    : "No business applications match your search.";
  $("#request-empty").hidden = filtered.length > 0;
  $("#request-table").querySelectorAll("[data-request-details]").forEach((button) => button.addEventListener("click", () => showRequest(button.dataset.requestDetails)));
}

function renderAll() {
  renderSummary();
  renderBusinesses();
  renderUsers();
  renderRequests();
}

function showRequest(id) {
  const request = requests.find((item) => item.id === id);
  if (!request) return;
  activeRequestId = id;
  $("#request-dialog-title").textContent = `Business application: ${request.subject}`;
  $("#request-detail").innerHTML = `<div class="request-meta"><p>Owner<strong>${escapeHtml(request.name)}</strong></p><p>Business email<strong>${escapeHtml(request.email)}</strong></p><p>Contact phone<strong>${escapeHtml(request.phone)}</strong></p><p>Category<strong>${escapeHtml(request.category)}</strong></p><p>Submitted<strong>${formatDate(request.date)}</strong></p><p>Status<strong>${escapeHtml(request.status)}</strong></p></div><div class="request-message">${escapeHtml(request.message)}</div>`;
  setFeedback($("#request-feedback"), "");
  const pending = request.rawStatus === "pending";
  $("#approve-application").disabled = !pending;
  $("#reject-application").disabled = !pending;
  $("#request-dialog").showModal();
}

async function reviewApplication(decision) {
  const request = requests.find((item) => item.id === activeRequestId);
  if (!request || request.rawStatus !== "pending") return;
  const button = decision === "approved" ? $("#approve-application") : $("#reject-application");
  button.disabled = true;
  const feedback = $("#request-feedback");
  setFeedback(feedback, decision === "approved" ? "Accepting request and granting owner access…" : "Rejecting application…");
  try {
    const { data, error } = await supabase.rpc("review_business_application", {
      p_application_id: request.id,
      p_decision: decision,
    });
    if (error) {
      console.error("LoyalLoop admin application review failed.", error);
      const message = String(error.message || "").toLowerCase();
      const requiresAccount = message.includes("register and confirm") || message.includes("confirmed");
      setFeedback(feedback, requiresAccount
        ? "The applicant must create an account using this business email before you can accept the request."
        : "The application could not be reviewed. Check the browser console for the Supabase error.");
      return;
    }
    if (decision === "approved" && (typeof data !== "string" || !data)) {
      console.error("LoyalLoop accepted application did not return a business ID.", data);
      setFeedback(feedback, "The server did not confirm business creation and owner access. No success was reported.");
      return;
    }

    await loadAdminData();
    renderAll();
    $("#request-dialog").close();
  } catch (error) {
    console.error("LoyalLoop admin application review request failed.", error);
    setFeedback(feedback, "The review could not be completed. Check your connection and try again.");
  } finally {
    button.disabled = false;
  }
}

document.querySelectorAll("[data-close-dialog]").forEach((button) => button.addEventListener("click", () => button.closest("dialog").close()));
$("#business-search").addEventListener("input", renderBusinesses);
$("#user-search").addEventListener("input", renderUsers);
$("#user-role").addEventListener("change", renderUsers);
$("#request-search").addEventListener("input", renderRequests);
$("#approve-application").addEventListener("click", () => reviewApplication("approved"));
$("#reject-application").addEventListener("click", () => reviewApplication("rejected"));

try {
  await loadAdminData();
  renderAll();
} catch (error) {
  const note = $("#dashboard-data-note");
  if (note) note.textContent = error.message;
  renderAll();
}
