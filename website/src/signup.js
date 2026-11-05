// Email form and public Turnstile key only. Brevo credentials never reach the browser.
export function attachSignup(copy) {
  const form=document.querySelector('.signup-form');
  if(!form)return;
  const message=form.querySelector('.form-message');
  const submit=form.querySelector('[type=submit]');
  let settings=null,widget=null,widgetToken='';
  const say=key=>{message.textContent=copy[key] || copy.subscribeError;};
  const settingsPromise=fetch('/api/subscribe',{headers:{Accept:'application/json'}})
    .then(r=>r.ok?r.json():null).then(data=>{settings=data;return data;}).catch(()=>null);
  async function challenge() {
    const config=await settingsPromise;
    if(!config?.ready)return;
    if(!window.turnstile) {
      await new Promise((resolve,reject)=>{
        const script=document.createElement('script');script.src='https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';script.async=true;script.onload=resolve;script.onerror=reject;document.head.append(script);
      });
    }
    if(widget===null) widget=window.turnstile.render('#turnstile',{sitekey:config.siteKey,action:'subscribe',appearance:'interaction-only',theme:'dark',callback:token=>{widgetToken=token;},'expired-callback':()=>{widgetToken='';}});
  }
  form.addEventListener('focusin',()=>{void challenge().catch(()=>say('subscribeUnavailable'));},{once:true});
  document.querySelectorAll('[data-subscribe]').forEach(button=>button.addEventListener('click',()=>{
    const key=button.dataset.subscribe;
    if(['intel','windows'].includes(key)) form.elements[key].checked=true;
    form.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'center'});
    form.elements.email.focus({preventScroll:true});
  }));
  form.addEventListener('submit',async event=>{
    event.preventDefault();
    const data=new FormData(form);
    const email=String(data.get('email') || '').trim();
    const newsletter=data.get('newsletter')==='true',intel=data.get('intel')==='true',windows=data.get('windows')==='true';
    if(!form.elements.email.checkValidity() || !(newsletter||intel||windows)) {say('subscribeInvalid');form.elements.email.reportValidity();return;}
    await settingsPromise;
    if(!settings?.ready) {say('subscribeUnavailable');return;}
    if(!widgetToken) {await challenge().catch(()=>{});say('subscribeBusy');return;}
    submit.disabled=true;say('subscribeSending');
    try {
      const response=await fetch('/api/subscribe',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,newsletter,intel,windows,language:data.get('language'),website:data.get('website'),token:widgetToken}),signal:AbortSignal.timeout(20000)});
      const result=await response.json();
      if(response.ok && result.code==='confirmation_sent') {say('subscribeSuccess');form.reset();}
      else say(({invalid:'subscribeInvalid',unavailable:'subscribeUnavailable',rate_limited:'subscribeBusy',challenge:'subscribeBusy'})[result.code] || 'subscribeError');
    } catch {say('subscribeError');}
    finally {submit.disabled=false;widgetToken='';if(widget!==null)window.turnstile.reset(widget);}
  });
}
