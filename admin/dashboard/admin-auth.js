import { supabase } from "../../supabase.js";

const loginPath = "../../login.html";
const gate = document.getElementById("admin-auth-status");
const gateTitle = document.getElementById("admin-auth-title");
const gateMessage = document.getElementById("admin-auth-message");
const returnLink = document.getElementById("admin-auth-return");
const dashboard = document.getElementById("admin-dashboard");
let isSigningOut = false;

function showGate(title, message, showReturnLink = true) {
  gateTitle.textContent = title;
  gateMessage.textContent = message;
  returnLink.hidden = !showReturnLink;
  gate.hidden = false;
}

document.querySelectorAll("[data-admin-signout]").forEach((link) => {
  link.addEventListener("click", async (event) => {
    event.preventDefault();
    if (isSigningOut) return;

    isSigningOut = true;
    link.setAttribute("aria-disabled", "true");
    try {
      const { error } = await supabase.auth.signOut();
      if (error) throw error;
      window.location.replace(loginPath);
    } catch {
      isSigningOut = false;
      link.removeAttribute("aria-disabled");
      window.alert("LoyalLoop could not sign you out. Please try again.");
    }
  });
});

supabase.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT") window.location.replace(loginPath);
});

async function authorizeAdminDashboard() {
  let sessionResult;
  try {
    sessionResult = await supabase.auth.getSession();
  } catch {
    showGate("Unable to verify your session", "Check your connection and reload this page.", true);
    return;
  }

  if (sessionResult.error) {
    showGate("Unable to verify your session", "Check your connection and reload this page.", true);
    return;
  }
  if (!sessionResult.data.session) {
    window.location.replace(loginPath);
    return;
  }

  // getUser validates the stored session with Supabase Auth. Local session data
  // is never used to decide a user's role or platform privileges.
  let userResult;
  try {
    userResult = await supabase.auth.getUser();
  } catch {
    showGate("Unable to verify your session", "Check your connection and reload this page.", true);
    return;
  }

  if (userResult.error) {
    if (userResult.error.status === 401) {
      await supabase.auth.signOut().catch(() => {});
      window.location.replace(loginPath);
      return;
    }
    showGate("Unable to verify your session", "Check your connection and reload this page.", true);
    return;
  }

  const user = userResult.data.user;
  if (!user) {
    window.location.replace(loginPath);
    return;
  }

  // This public table SELECT is protected by platform_admins_select_admin,
  // which calls the SECURITY DEFINER helper and returns rows only while the
  // current Auth user is an active platform administrator.
  let adminResult;
  try {
    adminResult = await supabase
      .from("platform_admins")
      .select("user_id")
      .eq("user_id", user.id)
      .maybeSingle();
  } catch {
    showGate("Unable to verify admin access", "The authorization check could not be completed. Please try again.", true);
    return;
  }

  if (adminResult.error) {
    showGate("Unable to verify admin access", "The authorization check could not be completed. Please try again.", true);
    return;
  }
  if (!adminResult.data) {
    showGate("Access denied", "This account is not an active LoyalLoop Platform Admin.", true);
    return;
  }

  try {
    // Load dashboard code only after both Auth and database authorization checks pass.
    await import("./dashboard.js");
    gate.hidden = true;
    dashboard.hidden = false;
  } catch (error) {
    console.error("Admin dashboard module failed after access verification.", error);
    showGate("Dashboard unavailable", "Admin access was verified, but the dashboard could not be loaded. Reload to try again.", true);
  }
}

authorizeAdminDashboard();
