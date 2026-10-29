import { supabase } from "../../supabase.js";

const $=selector=>document.querySelector(selector);
const esc=value=>String(value??"").replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
const color=(value,fallback)=>typeof value==="string"&&/^#[\da-f]{6}$/i.test(value)?value:fallback;
const date=value=>new Intl.DateTimeFormat("en",{dateStyle:"medium"}).format(new Date(value));
function denied(message){$("#customer-business-app").hidden=true;$("#membership-denied").hidden=false;$("#membership-denied h1").textContent=message;}
async function load(){
 const {data:{session}}=await supabase.auth.getSession();if(!session){location.replace("/login.html");return;}
 const slug=decodeURIComponent(location.pathname.split("/").filter(Boolean).at(-1)||"");
 const [profile,membership]=await Promise.all([
  supabase.from("profiles").select("full_name").eq("user_id",session.user.id).maybeSingle(),
  supabase.from("customer_loyalty_memberships").select("id,business_id,program_id,enrolled_at,status").eq("customer_user_id",session.user.id).eq("status","active"),
 ]);
 if(profile.error||membership.error)throw new Error("Your account membership could not be checked.");
 const candidates=(membership.data||[]).filter(x=>x.status==="active");if(!candidates.length){denied("This loyalty card is unavailable for your account.");return;}
 const businesses=await supabase.from("businesses").select("id,slug,display_name,status").in("id",candidates.map(x=>x.business_id));
 if(businesses.error)throw businesses.error;
 const chosen=businesses.data.find(x=>x.slug===slug&&x.status==="active");
 const member=candidates.find(x=>x.business_id===chosen?.id);
 if(!chosen||!member){denied("This loyalty card is unavailable for your account.");return;}
 const [brand,program,redemptions,ledger,offers]=await Promise.all([
  supabase.from("business_branding").select("logo_path,background_color,primary_color,secondary_color,text_color,theme_name,welcome_message,description").eq("business_id",chosen.id).maybeSingle(),
  supabase.from("loyalty_programs").select("id,status").eq("id",member.program_id).maybeSingle(),
  supabase.from("reward_redemptions").select("id,reward_name_snapshot,stamps_redeemed,redeemed_at").eq("loyalty_membership_id",member.id).order("redeemed_at",{ascending:false}),
  supabase.from("stamp_transactions").select("stamp_delta,created_at").eq("loyalty_membership_id",member.id).order("created_at",{ascending:false}),
  supabase.from("business_offers").select("title,description,offer_type,value,terms,starts_at,ends_at").eq("business_id",chosen.id).eq("status","active").eq("is_public",true),
 ]);
 if([brand,program,redemptions,ledger,offers].some(x=>x.error))throw new Error("Loyalty details are not available under the current access policies.");
 const rule=program.data?.status==="active"?await supabase.from("reward_rules").select("stamps_required,reward_name,description,is_active,minimum_purchase,valid_until").eq("program_id",member.program_id).eq("is_active",true).maybeSingle():{data:null,error:null};if(rule.error)throw rule.error;
 const b=brand.data||{},r=rule.data,name=profile.data?.full_name||session.user.email||"Member",balance=Math.max(0,(ledger.data||[]).reduce((sum,x)=>sum+x.stamp_delta,0)),goal=r?.stamps_required||0,available=goal?Math.floor(balance/goal):0,progress=goal?balance%goal:0,active=program.data?.status==="active"&&!!r;
 const hero=$("#business-hero"),card=$("#loyalty-card-display");hero.style.setProperty("--business-background",color(b.background_color,"#F8F6F0"));hero.style.setProperty("--business-primary",color(b.primary_color,"#879780"));hero.style.setProperty("--business-text",color(b.text_color,"#292D28"));card.style.setProperty("--business-primary",color(b.primary_color,"#879780"));card.style.setProperty("--business-secondary",color(b.secondary_color,"#EDE6D7"));card.style.setProperty("--business-ink","#566B55");
 $("#business-theme").textContent=b.theme_name||chosen.display_name;$("#business-name").textContent=chosen.display_name;$("#business-welcome").textContent=b.welcome_message||"";$("#business-description").textContent=b.description||"";$("#card-business-context").textContent=chosen.display_name;$("#loyalty-business-name").textContent=chosen.display_name;document.title=`${chosen.display_name} Loyalty Card | LoyalLoop`;document.querySelectorAll(".business-name-inline").forEach(x=>x.textContent=chosen.display_name);
 $("#business-customer-first-name").textContent=name.split(" ")[0];$("#business-card-customer-name").textContent=name;$("#business-account-name").textContent=name;$("#business-account-avatar").textContent=name.charAt(0).toUpperCase();$("#business-account-description").textContent=session.user.email||"Signed-in LoyalLoop account";$("#customer-header-name").textContent=name;
 $("#card-status").textContent=active?"ACTIVE":"PAUSED";$(".business-membership-status").textContent=active?"Active membership":"Programme paused";
 if(b.logo_path){const {data}=await supabase.storage.from("business-logos").createSignedUrl(b.logo_path,3600);if(data?.signedUrl){$("#business-logo-image").src=data.signedUrl;$("#business-logo-image").hidden=false;$("#business-logo-initial").hidden=true;$("#loyalty-logo-mark").innerHTML=`<img src="${esc(data.signedUrl)}" alt="" />`;}}
 const logoInitial=chosen.display_name.charAt(0).toUpperCase();$("#business-logo-initial").textContent=logoInitial;if(!b.logo_path)$("#loyalty-logo-mark").textContent=logoInitial;
 $("#stamp-count").textContent=`${balance} / ${goal||"—"}`;$("#stamp-progress-message").textContent=available?`${available} reward${available===1?"":"s"} ready to enjoy`:goal?`${balance} of ${goal} stamps collected`:"No active reward rule";const track=$("#loyalty-progress-track");track.setAttribute("aria-valuemax",String(goal||1));track.setAttribute("aria-valuenow",String(goal?(available?goal:progress):0));$("#loyalty-progress-fill").style.width=`${goal?(available?100:progress/goal*100):0}%`;
 $("#loyalty-stamps").innerHTML=Array.from({length:Math.min(goal,20)},(_,i)=>`<span class="loyalty-stamp ${i<Math.min(balance,goal)?"earned":""}" aria-label="Stamp ${i+1}${i<Math.min(balance,goal)?", collected":", not collected"}">${i<Math.min(balance,goal)?"✓":""}</span>`).join("");$("#next-reward-name").textContent=r?.reward_name||"No active reward";$("#next-reward-description").textContent=r?.description||"";
 const rewardStatus=$("#customer-reward-status");rewardStatus.classList.toggle("available",available>0&&active);rewardStatus.textContent=!active?"This programme is not currently active.":available?`${available} reward${available===1?"":"s"} available. Show your card to the business team to redeem.`:goal?`${goal-progress} more stamp${goal-progress===1?"":"s"} until your next reward.`:"No active reward rule has been published.";
 const history=redemptions.data||[];$("#rewards-history-empty").hidden=history.length>0;$("#rewards-history-list").innerHTML=history.map(x=>`<article class="reward-history-row"><span class="reward-history-icon" aria-hidden="true">✳</span><span class="reward-history-name"><strong>${esc(x.reward_name_snapshot)}</strong><small>${esc(chosen.display_name)} · ${esc(x.id.slice(0,8))}</small></span><span class="reward-history-date">${date(x.redeemed_at)}</span><span class="reward-history-status">Redeemed</span></article>`).join("");
 const activeOffers=(offers.data||[]).filter(x=>(!x.starts_at||Date.parse(x.starts_at)<=Date.now())&&(!x.ends_at||Date.parse(x.ends_at)>=Date.now()));$("#customer-offers-empty").hidden=activeOffers.length>0;$("#customer-offers-grid").innerHTML=activeOffers.map(x=>`<article class="customer-offer-card active" style="--offer-primary:${color(b.primary_color,"#879780")}"><div class="customer-offer-heading"><h3>${esc(x.title)}</h3><span class="offer-status-label active">Active</span></div><p class="customer-offer-benefit">${esc(x.value||x.offer_type)}</p><p class="customer-offer-description">${esc(x.description||"")}</p><p class="customer-offer-meta">${x.ends_at?`Valid through ${date(x.ends_at)}`:"Currently available"}${x.terms?` · ${esc(x.terms)}`:""}</p></article>`).join("");
 $(".customer-demo-banner").innerHTML="<span aria-hidden=\"true\">i</span><p><strong>Your loyalty membership</strong> · Your account’s business data is protected by Supabase access policies.</p>";
 $("#customer-business-app").hidden=false;$("#membership-denied").hidden=true;
}
document.querySelectorAll("[data-demo-logout]").forEach(link=>link.addEventListener("click",async event=>{event.preventDefault();const {error}=await supabase.auth.signOut();if(!error)location.assign("/login.html");}));
load().catch(()=>denied("This loyalty card could not be loaded. Please sign in again or return to your businesses."));
