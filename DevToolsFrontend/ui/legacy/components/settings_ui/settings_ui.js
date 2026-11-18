var T=Object.defineProperty;var k=(e,t)=>{for(var n in t)T(e,n,{get:t[n],enumerable:!0})};var v={};k(v,{createControlForSetting:()=>E,createSettingCheckbox:()=>q,renderControlForSetting:()=>C,renderSettingSelect:()=>b});import"../../../components/settings/settings.js";import*as d from"../../../../core/common/common.js";import*as u from"../../../../core/i18n/i18n.js";import*as U from"../../../../core/platform/platform.js";import{Directives as R,html as a,nothing as l,render as y}from"../../../lit/lit.js";import*as S from"../../../settings/settings.js";import*as g from"../../../visual_logging/visual_logging.js";import*as i from"../../legacy.js";var{createRef:L,ref:D}=R,c={srequiresReload:"*Requires reload",settingsChangedReloadDevTools:"Settings changed. To apply, reload DevTools."},w=u.i18n.registerUIStrings("ui/legacy/components/settings_ui/SettingsUI.ts",c),p=u.i18n.getLocalizedString.bind(void 0,w);function q(e,t,n){let o=i.UIUtils.CheckboxLabel.create(e,void 0,void 0,t.name);return o.name=e,i.UIUtils.bindCheckbox(o,t),n&&i.Tooltip.Tooltip.install(o,n),o}function b(e,t,n){let o=S.SettingUIRegistration.resolve(e.descriptor()),s=o.title,f=o.options,I=o.reloadRequired,h=i.ARIAUtils.nextId("labelledControl"),m=L(),$=r=>{let x=r.target;e.set(f[x.selectedIndex].value),I&&(i.InspectorView.InspectorView.instance().displayReloadRequiredWarning(p(c.settingsChangedReloadDevTools)),m.value&&m.value.classList.remove("hidden"))};return a`
    <div class=${R.classMap({"chrome-select-label":!!t})}>
      <p class="settings-select">
        <label for=${h}>
          ${s}
          ${t?a`<p>${t}</p>`:l}
        </label>
        <select
          id=${h}
          aria-label=${s}
          .disabled=${!!n}
          @change=${$}
          jslog=${g.dropDown().track({change:!0}).context(e.name)}
        >
          ${f.map(r=>r.text&&typeof r.value=="string"?a`
                <option
                  value=${r.value}
                  .selected=${e.get()===r.value}
                  jslog=${g.item(U.StringUtilities.toKebabCase(r.value)).track({click:!0})}
                >
                  ${r.text}
                </option>
              `:l)}
        </select>
      </p>
      ${I?a`
        <p ${D(m)} class="reload-warning hidden" role="alert" aria-live="polite">
          ${p(c.srequiresReload)}
        </p>`:l}
    </div>
  `}var C=function(e,t,n){switch(e.type()){case d.Settings.SettingType.BOOLEAN:return a`<setting-checkbox .data=${{setting:e,disabled:n}} @change=${()=>{S.SettingUIRegistration.maybeResolve(e.descriptor())?.reloadRequired&&i.InspectorView.InspectorView.instance().displayReloadRequiredWarning(p(c.settingsChangedReloadDevTools))}}></setting-checkbox>`;case d.Settings.SettingType.ENUM:return b(e,t,n);default:return console.error("Invalid setting type: "+e.type()),l}},E=function(e,t,n){let o=C(e,t,n);if(o===l)return null;let s=document.createDocumentFragment();return y(o,s),s.firstElementChild};export{v as SettingsUI};
//# sourceMappingURL=settings_ui.js.map
