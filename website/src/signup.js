// Public email form only. Sheet URL and shared secret stay on the server.
export function attachSignup(copy) {
  const form=document.querySelector('.signup-form');
  if(!form)return;
  const message=form.querySelector('.form-message');
  const submit=form.querySelector('[type=submit]');
  let settings=null,submitting=false;
  const say=key=>{message.textContent=copy[key] || copy.subscribeError;};
  const settingsPromise=fetch('/api/subscribe',{headers:{Accept:'application/json'}})
    .then(r=>r.ok?r.json():null).then(data=>{settings=data;if(!data?.ready)say(data?.ready===false?'subscribeUnavailable':'subscribeError');return data;}).catch(()=>{say('subscribeError');return null;});
  document.querySelectorAll('[data-subscribe]').forEach(button=>button.addEventListener('click',()=>{
    const key=button.dataset.subscribe;
    if(['intel','windows'].includes(key)) form.elements[key].checked=true;
    form.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'instant':'smooth',block:'center'});
    form.elements.email.focus({preventScroll:true});
  }));
  form.addEventListener('submit',async event=>{
    event.preventDefault();
    if(submitting)return;
    const data=new FormData(form);
    const email=String(data.get('email') || '').trim();
    const newsletter=data.get('newsletter')==='true',intel=data.get('intel')==='true',windows=data.get('windows')==='true';
    if(!form.elements.email.checkValidity() || !(newsletter||intel||windows)) {say('subscribeInvalid');form.elements.email.reportValidity();return;}
    submitting=true;submit.disabled=true;
    const buttonContent=submit.innerHTML;
    submit.textContent=copy.subscribeSending;form.setAttribute('aria-busy','true');say('subscribeSending');
    try {
      await settingsPromise;
      if(!settings?.ready) {say(settings?.ready===false?'subscribeUnavailable':'subscribeError');return;}
      const response=await fetch('/api/subscribe',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email,newsletter,intel,windows,language:data.get('language'),website:data.get('website')}),signal:AbortSignal.timeout(20000)});
      const result=await response.json();
      if(response.ok && result.code==='registered') {say('subscribeSuccess');form.reset();}
      else say(({invalid:'subscribeInvalid',unavailable:'subscribeUnavailable',rate_limited:'subscribeBusy'})[result.code] || 'subscribeError');
    } catch {say('subscribeError');}
    finally {submitting=false;submit.disabled=false;submit.innerHTML=buttonContent;form.removeAttribute('aria-busy');}
  });
}
