import { supabase } from "./supabase.js";

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function setMessage(element, text, isSuccess = false) {
  element.textContent = text;
  element.classList.toggle("is-success", isSuccess);
  element.style.color = isSuccess ? "#566B55" : "";
}

function clearInvalid(form) {
  form.querySelectorAll("[aria-invalid='true']").forEach((field) => {
    field.removeAttribute("aria-invalid");
  });
}

function setSubmitting(form, button, isSubmitting) {
  form.setAttribute("aria-busy", String(isSubmitting));
  button.disabled = isSubmitting;
}

function getAuthErrorMessage(error, action) {
  const code = String(error?.code || "").toLowerCase();
  const message = String(error?.message || "").toLowerCase();
  const status = Number(error?.status || 0);

  if (code === "user_already_exists" || code === "email_exists" || message.includes("already registered") || message.includes("already exists")) {
    return "An account with this email address already exists. Try signing in instead.";
  }
  if (code === "weak_password" || message.includes("password") && (message.includes("weak") || message.includes("least"))) {
    return "That password is too weak. Choose a stronger password and try again.";
  }
  if (code === "signup_disabled" || code === "email_provider_disabled") {
    return "Email registration is currently unavailable. Please contact support.";
  }
  if (code === "over_email_send_rate_limit" || code === "over_request_rate_limit" || status === 429) {
    return "Too many registration attempts. Wait a little while, then try again.";
  }
  if (code === "captcha_failed" || code === "captcha_required") {
    return "The security check couldn't be completed. Refresh the page and try again.";
  }
  if (code === "email_not_confirmed" || message.includes("email not confirmed")) {
    return "Confirm your email address using the link we sent before signing in.";
  }
  if (code === "invalid_credentials" || code === "invalid_grant" || message.includes("invalid login credentials")) {
    return "The email address or password is incorrect.";
  }
  if (error instanceof TypeError || message.includes("network") || message.includes("fetch")) {
    return "Unable to reach LoyalLoop right now. Check your internet connection and try again.";
  }
  if (action === "register" && (code === "invalid_email" || message.includes("invalid email"))) {
    return "Enter a valid email address and try again.";
  }
  if (action === "register") {
    return code
      ? `We couldn't create your account right now (error: ${code}). Please try again later.`
      : "We couldn't create your account right now. Please try again later.";
  }
  return code
    ? `We couldn't sign you in right now (error: ${code}). Please try again later.`
    : "We couldn't sign you in right now. Please try again later.";
}

async function getAuthorizedDashboardPath(userId) {
  const { data: adminRecord, error: adminError } = await supabase
    .from("platform_admins")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (adminError) {
    throw new Error("Your sign-in succeeded, but LoyalLoop couldn't verify your dashboard access. Please try again.");
  }
  if (adminRecord) return "/admin/dashboard/";

  const { data: memberships, error: membershipError } = await supabase
    .from("business_memberships")
    .select("role")
    .eq("user_id", userId)
    .eq("status", "active");
  if (membershipError) {
    throw new Error("Your sign-in succeeded, but LoyalLoop couldn't verify your dashboard access. Please try again.");
  }

  const roles = new Set((memberships || []).map((membership) => membership.role));
  if (roles.has("owner")) return "/owner/dashboard/";
  if (roles.has("staff")) return "/staff/dashboard";

  const { data: customerProfile, error: customerError } = await supabase
    .from("customer_profiles")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (customerError) {
    throw new Error("Your sign-in succeeded, but LoyalLoop couldn't verify your dashboard access. Please try again.");
  }
  if (customerProfile) return "/customer/dashboard";

  throw new Error("You signed in successfully, but no active LoyalLoop role was found for this account. Contact an administrator.");
}

document.querySelectorAll("[data-password-toggle]").forEach((button) => {
  button.addEventListener("click", () => {
    const input = document.getElementById(button.dataset.passwordToggle);
    const visible = input.type === "password";
    input.type = visible ? "text" : "password";
    button.textContent = visible ? "Hide" : "Show";
    button.setAttribute("aria-pressed", String(visible));
  });
});

document.querySelectorAll("[data-notice]").forEach((link) => {
  link.addEventListener("click", (event) => {
    event.preventDefault();
    setMessage(document.getElementById("login-message"), "Password recovery is not available yet.");
  });
});

const loginForm = document.getElementById("login-form");
if (loginForm) {
  const message = document.getElementById("login-message");
  const submitButton = loginForm.querySelector("button[type='submit']");
  let isSubmitting = false;

  loginForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (isSubmitting) return;

    clearInvalid(loginForm);
    const email = loginForm.elements.email;
    const password = loginForm.elements.password;
    const errors = [];

    if (!email.value.trim()) {
      errors.push("Enter your email address.");
      email.setAttribute("aria-invalid", "true");
    } else if (!emailPattern.test(email.value.trim())) {
      errors.push("Enter a valid email address.");
      email.setAttribute("aria-invalid", "true");
    }
    if (!password.value) {
      errors.push("Enter your password.");
      password.setAttribute("aria-invalid", "true");
    }

    if (errors.length) {
      setMessage(message, errors.join(" "));
      return;
    }

    isSubmitting = true;
    setSubmitting(loginForm, submitButton, true);
    setMessage(message, "Signing you in…");
    try {
      const { data, error } = await supabase.auth.signInWithPassword({
        email: email.value.trim(),
        password: password.value,
      });
      if (error) {
        setMessage(message, getAuthErrorMessage(error, "login"));
        return;
      }

      if (!data.user?.id) {
        setMessage(message, "Your sign-in succeeded, but LoyalLoop couldn't verify your dashboard access. Please try again.");
        return;
      }

      const dashboardPath = await getAuthorizedDashboardPath(data.user.id);
      setMessage(message, "Sign-in successful. Redirecting to your dashboard…", true);
      window.location.assign(dashboardPath);
    } catch (error) {
      const isDashboardAuthorizationError = error instanceof Error
        && (error.message.startsWith("Your sign-in succeeded")
          || error.message.startsWith("You signed in successfully"));
      setMessage(message, isDashboardAuthorizationError
        ? error.message
        : getAuthErrorMessage(error, "login"));
    } finally {
      isSubmitting = false;
      setSubmitting(loginForm, submitButton, false);
    }
  });
  loginForm.addEventListener("input", () => clearInvalid(loginForm));
}

const registerForm = document.getElementById("register-form");
if (registerForm) {
  const message = document.getElementById("register-message");
  const submitButton = registerForm.querySelector("button[type='submit']");
  let isSubmitting = false;

  registerForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (isSubmitting) return;

    clearInvalid(registerForm);
    const name = registerForm.elements.name;
    const phone = registerForm.elements.phone;
    const email = registerForm.elements.email;
    const password = registerForm.elements.password;
    const errors = [];

    if (!name.value.trim()) {
      errors.push("Enter your full name.");
      name.setAttribute("aria-invalid", "true");
    }
    const phoneDigits = phone.value.replace(/\D/g, "");
    if (!phone.value.trim()) {
      errors.push("Enter your phone number.");
      phone.setAttribute("aria-invalid", "true");
    } else if (phoneDigits.length < 7 || phoneDigits.length > 15) {
      errors.push("Enter a valid phone number with 7 to 15 digits.");
      phone.setAttribute("aria-invalid", "true");
    }
    if (!email.value.trim()) {
      errors.push("Enter your email address.");
      email.setAttribute("aria-invalid", "true");
    } else if (!emailPattern.test(email.value.trim())) {
      errors.push("Enter a valid email address.");
      email.setAttribute("aria-invalid", "true");
    }
    if (!password.value) {
      errors.push("Create a password.");
      password.setAttribute("aria-invalid", "true");
    } else if (password.value.length < 8) {
      errors.push("Your password must be at least 8 characters.");
      password.setAttribute("aria-invalid", "true");
    }

    if (errors.length) {
      setMessage(message, errors.join(" "));
      return;
    }

    isSubmitting = true;
    setSubmitting(registerForm, submitButton, true);
    setMessage(message, "Creating your account…");
    try {
      const { data, error } = await supabase.auth.signUp({
        email: email.value.trim(),
        password: password.value,
        options: {
          // These are user-provided profile details only; no roles or access
          // permissions are accepted from signup metadata.
          data: {
            full_name: name.value.trim(),
            phone: phone.value.trim(),
          },
        },
      });

      if (error) {
        console.error("LoyalLoop registration failed", {
          code: error.code,
          status: error.status,
          message: error.message,
        });
        setMessage(message, getAuthErrorMessage(error, "register"));
      } else {
        if (!data.session || !data.user?.id) {
          setMessage(message, "Your account was created, but automatic sign-in is unavailable. Sign in to continue.");
          return;
        }

        const dashboardPath = await getAuthorizedDashboardPath(data.user.id);
        setMessage(message, "Your account was created. Redirecting to your dashboard…", true);
        window.location.assign(dashboardPath);
      }
    } catch (error) {
      console.error("LoyalLoop registration request failed", {
        code: error?.code,
        status: error?.status,
        message: error?.message || String(error),
      });
      const isDashboardAuthorizationError = error instanceof Error
        && (error.message.startsWith("Your sign-in succeeded")
          || error.message.startsWith("You signed in successfully"));
      setMessage(message, isDashboardAuthorizationError
        ? error.message
        : getAuthErrorMessage(error, "register"));
    } finally {
      isSubmitting = false;
      setSubmitting(registerForm, submitButton, false);
    }
  });
  registerForm.addEventListener("input", () => clearInvalid(registerForm));
}

const forgotLink = document.getElementById("forgot-password-link");
const resetDialog = document.getElementById("reset-password-dialog");
const resetForm = document.getElementById("reset-password-form");
const resetMessage = document.getElementById("reset-message");
const resetSubmit = resetForm ? resetForm.querySelector("button[type='submit']") : null;
let resetSubmitting = false;

if (forgotLink && resetDialog) {
  forgotLink.addEventListener("click", (event) => {
    event.preventDefault();
    resetMessage.textContent = "";
    resetForm.reset();
    resetDialog.showModal();
    resetForm.elements.email.focus();
  });
}

document.getElementById("close-reset-password").addEventListener("click", () => resetDialog.close());
document.getElementById("close-reset-password-cancel").addEventListener("click", () => resetDialog.close());

if (resetForm) {
  resetForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (resetSubmitting) return;
    const email = resetForm.elements.email;
    if (!email.value.trim()) {
      resetMessage.textContent = "Enter your email address.";
      email.setAttribute("aria-invalid", "true");
      return;
    }
    if (!emailPattern.test(email.value.trim())) {
      resetMessage.textContent = "Enter a valid email address.";
      email.setAttribute("aria-invalid", "true");
      return;
    }
    resetSubmitting = true;
    resetSubmit.disabled = true;
    resetSubmit.textContent = "Sending…";
    try {
      const { error } = await supabase.auth.resetPasswordForEmail(email.value.trim(), {
        redirectTo: `${window.location.origin}/login.html`,
      });
      if (error) {
        resetMessage.textContent = getAuthErrorMessage(error, "reset");
        return;
      }
      resetDialog.close();
      setMessage(document.getElementById("login-message"), "A password reset link was sent to your email address.", true);
    } catch (error) {
      resetMessage.textContent = getAuthErrorMessage(error, "reset");
    } finally {
      resetSubmitting = false;
      resetSubmit.disabled = false;
      resetSubmit.textContent = "Send reset link";
    }
  });
  resetForm.addEventListener("input", () => {
    resetMessage.textContent = "";
    resetForm.elements.email.removeAttribute("aria-invalid");
  });
}
