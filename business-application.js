import { supabase } from "./supabase.js";

const dialog = document.getElementById("business-application-dialog");
const form = document.getElementById("business-application-form");
const message = document.getElementById("business-application-message");
const submitButton = form.querySelector("button[type='submit']");
const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
let isSubmitting = false;

function setMessage(text, success = false) {
  message.textContent = text;
  message.style.color = success ? "#566B55" : "";
}

document.getElementById("open-business-application").addEventListener("click", () => {
  setMessage("");
  dialog.showModal();
  form.elements.business_name.focus();
});

document.getElementById("close-business-application").addEventListener("click", () => dialog.close());

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if (isSubmitting) return;

  form.querySelectorAll("[aria-invalid='true']").forEach((field) => field.removeAttribute("aria-invalid"));
  setMessage("");
  const values = Object.fromEntries(new FormData(form).entries());
  const errors = [];
  const phoneDigits = values.contact_phone.replace(/\D/g, "");

  if (!values.business_name.trim()) errors.push([form.elements.business_name, "Enter the business name."]);
  if (!values.owner_full_name.trim()) errors.push([form.elements.owner_full_name, "Enter the owner's full name."]);
  if (!emailPattern.test(values.business_email.trim())) errors.push([form.elements.business_email, "Enter a valid business email."]);
  if (phoneDigits.length < 7 || phoneDigits.length > 15) errors.push([form.elements.contact_phone, "Enter a phone number with 7 to 15 digits."]);
  if (!values.category) errors.push([form.elements.category, "Choose a business category."]);
  if (values.description.length > 500) errors.push([form.elements.description, "Keep the description under 500 characters."]);

  if (errors.length) {
    errors.forEach(([field]) => field.setAttribute("aria-invalid", "true"));
    setMessage(errors.map(([, text]) => text).join(" "));
    return;
  }

  isSubmitting = true;
  form.setAttribute("aria-busy", "true");
  submitButton.disabled = true;
  submitButton.textContent = "Submitting…";
  setMessage("Submitting your application…");

  try {
    const { data: applicationId, error } = await supabase.rpc("submit_business_application", {
      p_business_name: values.business_name.trim(),
      p_owner_full_name: values.owner_full_name.trim(),
      p_business_email: values.business_email.trim(),
      p_contact_phone: values.contact_phone.trim(),
      p_category: values.category,
      p_description: values.description.trim() || null,
    });

    if (error) {
      const serverMessage = String(error.message || "").toLowerCase();
      if (serverMessage.includes("submitted recently") || error.code === "23505") {
        setMessage("An application using this business email was submitted recently. Please wait before trying again.");
      } else if (error.code === "PGRST202" || error.code === "42883") {
        setMessage("Business applications are not configured yet. Please try again later.");
      } else {
        setMessage("We couldn't submit your application. Please check the details and try again.");
      }
      return;
    }

    if (typeof applicationId !== "string" || !applicationId) {
      setMessage("We couldn't confirm that your application was saved. Please try again or contact LoyalLoop.");
      return;
    }

    form.reset();
    setMessage("Your application was submitted. A LoyalLoop admin will review it before any business access is created.", true);
  } catch (error) {
    const isNetworkError = error instanceof TypeError || /network|fetch/i.test(String(error?.message || ""));
    setMessage(isNetworkError
      ? "Unable to reach LoyalLoop right now. Check your connection and try again."
      : "We couldn't submit your application. Please try again.");
  } finally {
    isSubmitting = false;
    form.removeAttribute("aria-busy");
    submitButton.disabled = false;
    submitButton.textContent = "Submit application";
  }
});

form.addEventListener("input", (event) => {
  if (event.target.matches("[aria-invalid='true']")) event.target.removeAttribute("aria-invalid");
});
