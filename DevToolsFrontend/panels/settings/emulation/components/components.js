var Y=Object.defineProperty;var Z=(o,r)=>{for(var a in r)Y(o,a,{get:r[a],enumerable:!0})};var _={};Z(_,{ALL_PROTOCOL_FORM_FACTORS:()=>x,DEFAULT_VIEW:()=>N,Events:()=>P,UserAgentClientHintsForm:()=>w});import"../../../../ui/kit/kit.js";import*as U from"../../../../core/common/common.js";import*as V from"../../../../core/i18n/i18n.js";import*as I from"../../../../core/platform/platform.js";import*as k from"../../../../ui/components/buttons/buttons.js";import*as H from"../../../../ui/components/input/input.js";import*as D from"../../../../ui/legacy/legacy.js";import*as $ from"../../../../ui/lit/lit.js";import*as c from"../../../../ui/visual_logging/visual_logging.js";import*as T from"../utils/utils.js";var S=`@scope to (devtools-widget > *){:scope *{box-sizing:revert}:scope input{margin:revert}.root{color:var(--sys-color-on-surface);width:100%}.tree-title{font-weight:700;display:flex;align-items:center;& > [aria-controls="form-container"]{margin-left:var(--sys-size-2);padding-right:var(--sys-size-3);& > [name="triangle-right"],
      & > [name="triangle-down"]{vertical-align:bottom}&[aria-expanded="true"] > [name="triangle-right"]{display:none}&[aria-expanded="false"] > [name="triangle-down"]{display:none}}}.form-container{display:grid;grid-template-columns:1fr 1fr 1fr auto;align-items:center;gap:var(--sys-size-5) 10px;padding:0 10px}.full-row{grid-column:1/5}.form-factors-checkbox-group{display:grid;grid-template-columns:repeat(2,1fr);gap:var(--sys-size-4) 10px}.form-factor-checkbox-label{display:flex;align-items:center;gap:var(--sys-size-4);white-space:nowrap}hr.section-separator{grid-column:1/5;border:none;margin-top:var(--sys-size-1)}.half-row{grid-column:span 2}.mobile-checkbox-container{display:flex}.device-model-input{grid-column:1/4}.input-field{color:var(--sys-color-on-surface);padding:3px var(--sys-size-4);border-radius:var(--sys-size-2);border:var(--sys-size-1) solid var(--sys-color-neutral-outline);background-color:var(--sys-color-cdt-base-container);font-family:inherit;font-size:inherit;height:18px}.input-field::placeholder{color:var(--sys-color-on-surface-subtle)}.input-field:focus{border:var(--sys-size-1) solid var(--sys-color-state-focus-ring);outline-style:none}.add-container{cursor:pointer;display:flex;align-items:center;gap:var(--sys-size-4)}.add-icon{margin-right:5px}.brand-row{display:flex;align-items:center;gap:10px;justify-content:space-between}.brand-row > input{width:100%}.info-icon{margin-left:5px;margin-right:var(--sys-size-1);height:var(--sys-size-8);width:var(--sys-size-8)}.link,
  .devtools-link{color:var(--sys-color-primary);text-decoration:underline;cursor:pointer;outline-offset:var(--sys-size-2);font-weight:400}devtools-icon + .link{margin-inline-start:var(--sys-size-2)}.hide-container{display:none}.input-field-label-container{display:flex;flex-direction:column;gap:10px}@media (forced-colors: active){.input-field{border:var(--sys-size-1) solid}.tree-title[aria-disabled="true"]{color:GrayText}}}
/*# sourceURL=${import.meta.resolve("./userAgentClientHintsForm.css")} */`;var{html:p,Directives:{ref:ee}}=$,e={title:"User agent client hints",useragent:"User agent (Sec-CH-UA)",fullVersionList:"Full version list (Sec-CH-UA-Full-Version-List)",brandProperties:"User agent properties",brandName:"Brand",brandNameAriaLabel:"Brand {PH1}",significantBrandVersionPlaceholder:"Significant version (e.g. 87)",brandVersionPlaceholder:"Version (e.g. 87.0.4280.88)",brandVersionAriaLabel:"Version {PH1}",addBrand:"Add brand",brandUserAgentDelete:"Delete brand from user agent section",brandFullVersionListDelete:"Delete brand from full version list",formFactorsTitle:"Form factors (Sec-CH-UA-Form-Factors)",formFactorsGroupAriaLabel:"Available form factors",formFactorDesktop:"Desktop",formFactorAutomotive:"Automotive",formFactorMobile:"Mobile",formFactorTablet:"Tablet",formFactorXR:"XR",formFactorEInk:"EInk",formFactorWatch:"Watch",fullBrowserVersion:"Full browser version (Sec-CH-UA-Full-Version)",fullBrowserVersionPlaceholder:"Full browser version (e.g. 87.0.4280.88)",platformLabel:"Platform (Sec-CH-UA-Platform / Sec-CH-UA-Platform-Version)",platformProperties:"Platform properties",platformVersion:"Platform version",platformPlaceholder:"Platform (e.g. Android)",architecture:"Architecture (Sec-CH-UA-Arch)",architecturePlaceholder:"Architecture (e.g. x86)",deviceProperties:"Device properties",deviceModel:"Device model (Sec-CH-UA-Model)",mobileCheckboxLabel:"Mobile",update:"Update",notRepresentable:"Not representable as structured headers string",userAgentClientHintsInfo:"User agent client hints are an alternative to the user agent string that identify the browser and the device in a more structured way with better privacy accounting",addedBrand:"Added brand row",deletedBrand:"Deleted brand row",learnMore:"Learn more"},te=V.i18n.registerUIStrings("panels/settings/emulation/components/UserAgentClientHintsForm.ts",e),t=V.i18n.getLocalizedString.bind(void 0,te),P=(a=>(a.CLIENT_HINTS_CHANGE="clienthintschange",a.CLIENT_HINTS_SUBMIT="clienthintssubmit",a))(P||{}),M={brands:[{brand:"",version:""}],fullVersionList:[{brand:"",version:""}],fullVersion:"",platform:"",platformVersion:"",architecture:"",model:"",mobile:!1,formFactors:[]},x=[e.formFactorDesktop,e.formFactorAutomotive,e.formFactorMobile,e.formFactorTablet,e.formFactorXR,e.formFactorEInk,e.formFactorWatch],re={brands:"ua",fullVersionList:"fvl"},oe={brands:"add-brand-button",fullVersionList:"add-fvl-brand-button"},ae=U.ObjectWrapper.eventMixin(D.Widget.Widget),w=class extends ae{#i;#o={};#t=!1;#r=!1;#e=M;#s=!1;#a=!1;#n="";constructor(r,a=N){super(r),this.#i=a}set value(r){let{metaData:a=M,showMobileCheckbox:n=!1,showSubmitButton:u=!1}=r;this.#e={...this.#e,...a},this.#s=n,this.#a=u,this.requestUpdate()}get value(){return{metaData:this.#e}}set disabled(r){this.#r!==r&&(this.#r=r,r&&(this.#t=!1),this.requestUpdate())}get disabled(){return this.#r}wasShown(){super.wasShown(),this.requestUpdate()}#d=r=>{this.#r||r==="ArrowLeft"&&!this.#t||r==="ArrowRight"&&this.#t||(this.#t=!this.#t,this.requestUpdate())};#c=(r,a,n,u)=>{let h=this.#e[r]?.map((f,E)=>{if(E===a){let{brand:y,version:A}=f;return n==="brandName"?{brand:u,version:A}:{brand:y,version:u}}return f});this.#e={...this.#e,[r]:h},this.dispatchEventToListeners("clienthintschange",this.#e),this.requestUpdate()};#u=async(r,a)=>{let{[r]:n=[]}=this.#e,u=n.filter((h,f)=>f!==a);this.#e={...this.#e,[r]:u},this.dispatchEventToListeners("clienthintschange",this.#e),this.#n=t(e.deletedBrand),this.requestUpdate(),await this.updateComplete,a<u.length?this.#o.focusBrandInput?.(r,a):this.#o.focusAddBrandButton?.(r)};#m=async r=>{let{[r]:a}=this.#e,n=[...Array.isArray(a)?a:[],{brand:"",version:""}];this.#e={...this.#e,[r]:n},this.dispatchEventToListeners("clienthintschange",this.#e),this.#n=t(e.addedBrand),this.requestUpdate(),await this.updateComplete,this.#o.focusBrandInput?.(r,n.length-1)};#p=(r,a)=>{let n=[...this.#e.formFactors||[]];a?n.includes(r)||n.push(r):n=n.filter(u=>u!==r),this.#e={...this.#e,formFactors:n},this.dispatchEventToListeners("clienthintschange",this.#e),this.requestUpdate()};#l=(r,a)=>{r in this.#e&&(this.#e={...this.#e,[r]:a},this.requestUpdate()),this.dispatchEventToListeners("clienthintschange",this.#e)};#b=()=>{this.#a&&(this.dispatchEventToListeners("clienthintssubmit",this.#e),this.requestUpdate())};validate=()=>{for(let[r,a]of Object.entries(this.#e))if(r==="brands"||r==="fullVersionList"){if(!(a??[]).every(({brand:h,version:f})=>{let E=T.UserAgentMetadata.validateAsStructuredHeadersString(h,t(e.notRepresentable)),y=T.UserAgentMetadata.validateAsStructuredHeadersString(f,t(e.notRepresentable));return E.valid&&y.valid}))return{valid:!1,errorMessage:t(e.notRepresentable)}}else if(r==="formFactors"){let n=a;if(n)for(let u of n){if(!x.includes(u))return{valid:!1,errorMessage:t(e.notRepresentable)+` (Invalid form factor: ${u})`};let h=T.UserAgentMetadata.validateAsStructuredHeadersString(u,t(e.notRepresentable));if(!h.valid)return h}}else{let n=T.UserAgentMetadata.validateAsStructuredHeadersString(a,t(e.notRepresentable));if(!n.valid)return n}return{valid:!0}};performUpdate(){let r={brands:this.#e.brands??[{brand:"",version:""}],fullVersionList:this.#e.fullVersionList??[{brand:"",version:""}],fullVersion:this.#e.fullVersion||"",formFactors:this.#e.formFactors??[],platform:this.#e.platform,platformVersion:this.#e.platformVersion,architecture:this.#e.architecture,model:this.#e.model,mobile:this.#e.mobile,isFormOpened:this.#t,isFormDisabled:this.#r,showMobileCheckbox:this.#s,showSubmitButton:this.#a,useragentModifiedAriaMessage:this.#n,onTreeToggle:this.#d,onBrandAdd:a=>{this.#m(a)},onBrandDelete:(a,n)=>{this.#u(a,n)},onBrandInputChange:this.#c,onTextFieldChange:this.#l,onMobileChange:a=>this.#l("mobile",a),onFormFactorChange:this.#p,onSubmit:this.#b};this.#i(r,this.#o,this.contentElement)}},N=(o,r,a)=>{let n=(s,d,l,i)=>p`
      <label class="full-row label input-field-label-container">
        ${s}
        <input
          class="input-field"
          type="text"
          @input=${g=>{let v=g.target.value;o.onTextFieldChange(i,v)}}
          .value=${l}
          placeholder=${d}
          jslog=${c.textField().track({change:!0}).context(I.StringUtilities.toKebabCase(i))}
          />
      </label>
    `,u=()=>{let s=l=>{let i=l.target.value;o.onTextFieldChange("platform",i)},d=l=>{let i=l.target.value;o.onTextFieldChange("platformVersion",i)};return p`
      <span class="full-row label">${t(e.platformLabel)}</span>
      <div class="full-row brand-row" aria-label=${t(e.platformProperties)} role="group">
        <input
          class="input-field half-row"
          type="text"
          @input=${s}
          .value=${o.platform}
          placeholder=${t(e.platformPlaceholder)}
          aria-label=${t(e.platformLabel)}
          jslog=${c.textField("platform").track({change:!0})}
        />
        <input
          class="input-field half-row"
          type="text"
          @input=${d}
          .value=${o.platformVersion}
          placeholder=${t(e.platformVersion)}
          aria-label=${t(e.platformVersion)}
          jslog=${c.textField("platform-version").track({change:!0})}
        />
      </div>
    `},h=()=>{let s=i=>{let b=i.target.value;o.onTextFieldChange("model",b)},d=i=>{let b=i.target.checked;o.onMobileChange(b)},l=o.showMobileCheckbox?p`
      <label class="mobile-checkbox-container">
        <input type="checkbox" @input=${d} .checked=${o.mobile}
          jslog=${c.toggle("mobile").track({click:!0})}
        />
        ${t(e.mobileCheckboxLabel)}
      </label>
    `:$.nothing;return p`
      <span class="full-row label">${t(e.deviceModel)}</span>
      <div class="full-row brand-row" aria-label=${t(e.deviceProperties)} role="group">
        <input
          class="input-field ${o.showMobileCheckbox?"device-model-input":"full-row"}"
          type="text"
          @input=${s}
          .value=${o.model}
          placeholder=${t(e.deviceModel)}
          jslog=${c.textField("model").track({change:!0})}
        />
        ${l}
      </div>
    `},f=()=>{let s=o.brands.map((l,i)=>{let{brand:b,version:g}=l,v=()=>{o.onBrandDelete("brands",i)},B=m=>{(m.code==="Space"||m.code==="Enter")&&(m.preventDefault(),v())},C=m=>{let L=m.target.value;o.onBrandInputChange("brands",i,"brandName",L)},F=m=>{let L=m.target.value;o.onBrandInputChange("brands",i,"brandVersion",L)};return p`
        <div class="full-row brand-row" aria-label=${t(e.brandProperties)} role="group">
          <input
            class="input-field ua-brand-name-input"
            type="text"
            @input=${C}
            .value=${b}
            id="ua-brand-${i+1}-input"
            placeholder=${t(e.brandName)}
            aria-label=${t(e.brandNameAriaLabel,{PH1:i+1})}
            jslog=${c.textField("brand-name").track({change:!0})}
          />
          <input
            class="input-field"
            type="text"
            @input=${F}
            .value=${g}
            placeholder=${t(e.significantBrandVersionPlaceholder)}
            aria-label=${t(e.brandVersionAriaLabel,{PH1:i+1})}
            jslog=${c.textField("brand-version").track({change:!0})}
          />
          <devtools-icon name="bin"
            title=${t(e.brandUserAgentDelete)}
            class="medium delete-icon"
            tabindex="0"
            role="button"
            @click=${v}
            @keypress=${B}
            aria-label=${t(e.brandUserAgentDelete)}
          >
          </devtools-icon>
        </div>
      `}),d=l=>{(l.code==="Space"||l.code==="Enter")&&(l.preventDefault(),o.onBrandAdd("brands"))};return p`
      <span class="full-row label">${t(e.useragent)}</span>
      ${s}
      <div
        class="add-container full-row"
        role="button"
        tabindex="0"
        id="add-brand-button"
        aria-label=${t(e.addBrand)}
        @click=${()=>o.onBrandAdd("brands")}
        @keypress=${d}
      >
        <devtools-icon
          aria-hidden="true" name="plus" class="medium">
        </devtools-icon>
        ${t(e.addBrand)}
      </div>
    `},E=()=>{let s=o.fullVersionList.map((l,i)=>{let{brand:b,version:g}=l,v=()=>{o.onBrandDelete("fullVersionList",i)},B=m=>{(m.code==="Space"||m.code==="Enter")&&(m.preventDefault(),v())},C=m=>{let L=m.target.value;o.onBrandInputChange("fullVersionList",i,"brandName",L)},F=m=>{let L=m.target.value;o.onBrandInputChange("fullVersionList",i,"brandVersion",L)};return p`
        <div
          class="full-row brand-row"
          aria-label=${t(e.brandProperties)}
          jslog=${c.section("full-version")}
          role="group">
          <input
            class="input-field fvl-brand-name-input"
            type="text"
            @input=${C}
            .value=${b}
            id="fvl-brand-${i+1}-input"
            placeholder=${t(e.brandName)}
            aria-label=${t(e.brandNameAriaLabel,{PH1:i+1})}
            jslog=${c.textField("brand-name").track({change:!0})}
          />
          <input
            class="input-field"
            type="text"
            @input=${F}
            .value=${g}
            placeholder=${t(e.brandVersionPlaceholder)}
            aria-label=${t(e.brandVersionAriaLabel,{PH1:i+1})}
            jslog=${c.textField("brand-version").track({change:!0})}
          />
          <devtools-icon name="bin"
            title=${t(e.brandFullVersionListDelete)}
            class="medium delete-icon"
            tabindex="0"
            role="button"
            @click=${v}
            @keypress=${B}
            aria-label=${t(e.brandFullVersionListDelete)}
          >
          </devtools-icon>
        </div>
      `}),d=l=>{(l.code==="Space"||l.code==="Enter")&&(l.preventDefault(),o.onBrandAdd("fullVersionList"))};return p`
      <span class="full-row label">${t(e.fullVersionList)}</span>
      ${s}
      <div
        class="add-container full-row"
        role="button"
        tabindex="0"
        id="add-fvl-brand-button"
        aria-label=${t(e.addBrand)}
        @click=${()=>o.onBrandAdd("fullVersionList")}
        @keypress=${d}
      >
        <devtools-icon name="plus" class="medium"
          aria-hidden="true">
        </devtools-icon>
        ${t(e.addBrand)}
      </div>
    `},y=()=>{let s=x.map(d=>{let l=o.formFactors.includes(d),i=`formFactor${d}`,b=t(e[i]);return p`
        <label class="form-factor-checkbox-label">
          <input
            type="checkbox"
            .checked=${l}
            value=${d}
            jslog=${c.toggle(I.StringUtilities.toKebabCase(d)).track({click:!0})}
            @change=${g=>o.onFormFactorChange(d,g.target.checked)}
          />
          ${b}
        </label>
      `});return p`
      <span class="full-row label" jslog=${c.sectionHeader("form-factors")}>
        ${t(e.formFactorsTitle)}
      </span>
      <div class="full-row form-factors-checkbox-group" role="group" aria-label=${t(e.formFactorsGroupAriaLabel)}>
        ${s}
      </div>
    `},A=f(),R=E(),z=n(t(e.fullBrowserVersion),t(e.fullBrowserVersionPlaceholder),o.fullVersion,"fullVersion"),K=y(),j=u(),O=n(t(e.architecture),t(e.architecturePlaceholder),o.architecture,"architecture"),W=h(),q=s=>{(s.code==="Space"||s.code==="Enter"||s.code==="ArrowLeft"||s.code==="ArrowRight")&&(s.consume(!0),o.onTreeToggle(s.code))},G=s=>{s.preventDefault(),o.onSubmit()},X=s=>{if(!(s instanceof HTMLFormElement)){r.focusBrandInput=void 0,r.focusAddBrandButton=void 0;return}r.focusBrandInput=(d,l)=>{s.querySelector(`#${re[d]}-brand-${l+1}-input`)?.focus()},r.focusAddBrandButton=d=>{s.querySelector(`#${oe[d]}`)?.focus()}},J=o.showSubmitButton?p`
    <devtools-button
      .variant=${k.Button.Variant.OUTLINED}
      .type=${"submit"}
    >
      ${t(e.update)}
    </devtools-button>
  `:$.nothing,Q=p`
    <style>${H.checkboxStyles}</style>
    <style>${S}</style>
    <section class="root">
      <div class="tree-title">
        <div
          role=button
          @click=${()=>o.onTreeToggle()}
          tabindex=${o.isFormDisabled?"-1":"0"}
          @keydown=${q}
          aria-expanded=${o.isFormOpened}
          aria-controls=form-container
          aria-disabled=${o.isFormDisabled}
          aria-label=${t(e.title)}
          jslog=${c.toggleSubpane().track({click:!0})}>
          <devtools-icon name=triangle-right></devtools-icon>
          <devtools-icon name=triangle-down></devtools-icon>
          ${t(e.title)}
        </div>
        <devtools-icon tabindex=${o.isFormDisabled?"-1":"0"} class=info-icon name=info aria-label=${t(e.userAgentClientHintsInfo)} title=${t(e.userAgentClientHintsInfo)}></devtools-icon>
        <devtools-link
         tabindex=${o.isFormDisabled?"-1":"0"}
         href="https://web.dev/user-agent-client-hints/"
         class="link"
         aria-label=${t(e.learnMore)}
         jslogcontext="learn-more"
        >
          ${t(e.learnMore)}
        </devtools-link>
      </div>
      <form
        id="form-container"
        class="form-container ${o.isFormOpened?"":"hide-container"}"
        @submit=${G}
        ${ee(X)}
      >
        ${A}
        <hr class="section-separator">
        ${R}
        <hr class="section-separator">
        ${z}
        <hr class="section-separator">
        ${K}
        <hr class="section-separator">
        ${j}
        <hr class="section-separator">
        ${O}
        <hr class="section-separator">
        ${W}
        ${J}
      </form>
      <div aria-live="polite" aria-label=${o.useragentModifiedAriaMessage}></div>
    </section>
  `;$.render(Q,a)};export{_ as UserAgentClientHintsForm};
//# sourceMappingURL=components.js.map
