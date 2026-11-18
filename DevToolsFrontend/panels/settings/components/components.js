var B=Object.defineProperty;var w=(e,i)=>{for(var t in i)B(e,t,{get:i[t],enumerable:!0})};var P={};w(P,{SyncSection:()=>m,WarningType:()=>I});import"../../../ui/components/settings/settings.js";import"../../../ui/components/tooltips/tooltips.js";import"../../../ui/kit/kit.js";import*as f from"../../../core/common/common.js";import*as a from"../../../core/host/host.js";import*as v from"../../../core/i18n/i18n.js";import*as c from"../../../models/badges/badges.js";import*as l from"../../../ui/components/buttons/buttons.js";import*as u from"../../../ui/helpers/helpers.js";import*as y from"../../../ui/legacy/legacy.js";import*as r from"../../../ui/lit/lit.js";import*as b from"../../../ui/visual_logging/visual_logging.js";import*as C from"../../common/common.js";import*as E from"../../utils/utils.js";var h=`@scope to (devtools-widget > *){:scope{break-inside:avoid;display:block;width:100%;position:relative}fieldset{border:0;padding:0;padding:var(--sys-size-3) 0 0}.link{color:var(--sys-color-primary);text-decoration:underline;cursor:pointer;outline-offset:var(--sys-size-2)}.account-avatar{border:0;border-radius:var(--sys-shape-corner-full);display:block;height:var(--sys-size-9);width:var(--sys-size-9)}.account-info{display:flex;align-items:center}.account-email{display:flex;flex-direction:column;margin-left:var(--sys-size-5)}.not-signed-in{padding-bottom:var(--sys-size-3)}.setting-checkbox-container{display:flex;align-items:center;gap:var(--sys-size-2)}.setting-checkbox{display:inline-block}.gdp-profile-container{padding-bottom:var(--sys-size-4)}.gdp-profile-container .divider{left:0;position:absolute;width:100%;height:var(--sys-size-1);background:var(--sys-color-divider)}.gdp-profile-container .gdp-profile-header{display:flex;align-items:center;gap:var(--sys-size-5);font-family:"Google Sans",system-ui;font-size:var(--sys-typescale-body3-size);height:var(--sys-size-11)}.gdp-profile-container .gdp-profile-header .gdp-logo{background-image:var(--image-file-gdp-logo-light);background-size:contain;width:203px;height:18px;background-repeat:no-repeat}:host-context(.theme-with-dark-background) & .gdp-profile-container .gdp-profile-header .gdp-logo{background-image:var(--image-file-gdp-logo-dark)}.gdp-profile-container .gdp-profile-sign-up-content{padding-top:var(--sys-size-7);display:flex;justify-content:space-between;align-items:center}.gdp-profile-container .gdp-profile-details-content{padding-top:var(--sys-size-7);font:var(--sys-typescale-body4-regular)}.gdp-profile-container .gdp-profile-details-content .plan-details{margin-top:var(--sys-size-3);height:18px;display:flex;align-items:center}.gdp-profile-container .gdp-profile-details-content .setting-container{margin:calc(var(--sys-size-3) - var(--sys-size-4)) 0 calc(-1 * var(--sys-size-4));display:flex;align-items:center;gap:var(--sys-size-2)}.gdp-profile-container .gdp-profile-details-content .tooltip-content{max-width:278px;padding:var(--sys-size-2) var(--sys-size-3);font:var(--sys-typescale-body5-regular)}}
/*# sourceURL=${import.meta.resolve("./syncSection.css")} */`;var n={syncDisabled:"To turn this setting on, you must enable Chrome sync",preferencesSyncDisabled:"You need to first enable saving `Chrome` settings in your `Google` account",signedIn:"Signed in to Chrome as:",notSignedIn:"You\u2019re not signed in to Chrome",gdpStandardPlan:"Standard plan",gdpPremiumSubscription:"Premium",gdpProSubscription:"Pro",gdpUnknownSubscription:"Unknown plan",signUp:"Sign up",viewProfile:"View profile",tooltipDisclaimerText:"When you qualify for a badge, the badge\u2019s identifier and the type of activity you did to earn it are sent to Google",relevantData:"Relevant data",dataDisclaimer:"({PH1} is sent to Google)"},k=v.i18n.registerUIStrings("panels/settings/components/SyncSection.ts",n),o=v.i18n.getLocalizedString.bind(void 0,k),D=r.i18nTemplate.bind(void 0,k),{html:s,render:T,Directives:{ref:G}}=r;function U(e){if(!e.activeSubscription||e.activeSubscription.subscriptionStatus!==a.GdpClient.SubscriptionStatus.ENABLED)return o(n.gdpStandardPlan);switch(e.activeSubscription.subscriptionTier){case a.GdpClient.SubscriptionTier.PREMIUM_ANNUAL:case a.GdpClient.SubscriptionTier.PREMIUM_MONTHLY:return o(n.gdpPremiumSubscription);case a.GdpClient.SubscriptionTier.PRO_ANNUAL:case a.GdpClient.SubscriptionTier.PRO_MONTHLY:return o(n.gdpProSubscription);default:return o(n.gdpUnknownSubscription)}}var $=(e,i,t)=>{let g=()=>{if(!e.syncInfo.accountEmail)return r.nothing;let p=e.warningType==="SYNC_DISABLED"?o(n.syncDisabled):o(n.preferencesSyncDisabled);return s`
      <div class="setting-checkbox-container">
        <setting-checkbox class="setting-checkbox"
          .data=${{setting:e.syncSetting,disabled:e.checkboxDisabled}}>
        </setting-checkbox>
        ${e.warningType?s`
          <devtools-button
            aria-details="settings-sync-info"
            .iconName=${"info"}
            .variant=${l.Button.Variant.ICON}
            .size=${l.Button.Size.SMALL}
            @click=${e.onWarningClick}>
          </devtools-button>
          <devtools-tooltip
              id="settings-sync-info"
              variant="rich">
            ${p}
          </devtools-tooltip>`:r.nothing}
      </div>
    `},x=()=>e.syncInfo.accountEmail?s`
      <div class="account-info">
        <img class="account-avatar" src="data:image/png;base64, ${e.syncInfo.accountImage}"
          alt="Account avatar" />
        <div class="account-email">
          <span>${o(n.signedIn)}</span>
          <span>${e.syncInfo.accountEmail}</span>
        </div>
      </div>`:s`
        <div class="not-signed-in">${o(n.notSignedIn)}</div>
      `,L=()=>{if(!e.isEligibleToCreateGdpProfile&&!e.gdpProfile)return r.nothing;let p=a.GdpClient.isBadgesEnabled()&&e.receiveBadgesSetting,S=()=>s`
        <div class="gdp-profile-header">
          <div class="gdp-logo" role="img" aria-label="Google Developer Program"></div>
        </div>
      `;return s`
      <div class="gdp-profile-container" .jslog=${b.section().context("gdp-profile")}>
        <div class="divider"></div>
        ${e.gdpProfile?s`
          <div class="gdp-profile-details-content">
            ${S()}
            <div class="plan-details">
              ${U(e.gdpProfile)}
              &nbsp;·&nbsp;
              <devtools-link
                jslogcontext="view-profile"
                class="link"
                href=${a.GdpClient.GOOGLE_DEVELOPER_PROGRAM_PROFILE_LINK}>
                ${o(n.viewProfile)}
              </devtools-link></div>
              ${p?s`
                <div class="setting-container" ${G(d=>{i.highlightReceiveBadgesSetting=()=>{d&&E.PanelUtils.highlightElement(d)}})}>
                  <setting-checkbox class="setting-checkbox"
                    .data=${{setting:e.receiveBadgesSetting}}
                    @change=${d=>e.onReceiveBadgesSettingClick(d)}>
                  </setting-checkbox>
                  <span>${D(n.dataDisclaimer,{PH1:s`
                    <span class="link" tabindex="0" aria-details="gdp-profile-tooltip">
                      ${o(n.relevantData)}</span>
                    <devtools-tooltip id="gdp-profile-tooltip" variant="rich">
                      <div class="tooltip-content" tabindex="0">
                      ${o(n.tooltipDisclaimerText)}</div>
                    </devtools-tooltip>`})}
                  </span>
                </div>
              `:r.nothing}
          </div>
        `:s`
          <div class="gdp-profile-sign-up-content">
            ${S()}
            <devtools-button
              @click=${e.onSignUpClick}
              .jslogContext=${"open-sign-up-dialog"}
              .variant=${l.Button.Variant.OUTLINED}>
                ${o(n.signUp)}
            </devtools-button>
          </div>
        `}
      </div>
    `};T(s`
    <style>${h}</style>
    <fieldset>
      ${x()}
      ${g()}
      ${L()}
    </fieldset>
  `,t)},I=(t=>(t.SYNC_DISABLED="SYNC_DISABLED",t.PREFERENCES_SYNC_DISABLED="PREFERENCES_SYNC_DISABLED",t))(I||{}),m=class extends y.Widget.Widget{#e={isSyncActive:!1};#i;#t;#n=!1;#o;#s;#a={};constructor(i,t=$){super(i),this.#s=t,this.#t=f.Settings.Settings.instance().resolve(c.receiveGdpBadgesSettingDescriptor),this.#i=f.Settings.Settings.instance().moduleSetting("sync-preferences")}wasShown(){super.wasShown(),this.requestUpdate()}set syncInfo(i){this.#e=i,this.requestUpdate(),i.accountEmail&&this.#r()}async highlightReceiveBadgesSetting(){this.requestUpdate(),await this.updateComplete,this.#a.highlightReceiveBadgesSetting?.()}performUpdate(){let i=!this.#e.isSyncActive||!this.#e.arePreferencesSynced,t;this.#e.isSyncActive?this.#e.arePreferencesSynced||(t="PREFERENCES_SYNC_DISABLED"):t="SYNC_DISABLED";let g={syncInfo:this.#e,syncSetting:this.#i,checkboxDisabled:i,receiveBadgesSetting:this.#t,gdpProfile:this.#o,isEligibleToCreateGdpProfile:a.GdpClient.isGdpProfilesAvailable()&&this.#n,onSignUpClick:this.#c.bind(this),onReceiveBadgesSettingClick:this.#d.bind(this),onWarningClick:this.#l.bind(this),warningType:t};this.#s(g,this.#a,this.contentElement)}#c(){C.GdpSignUpDialog.show({onSuccess:this.#r.bind(this)})}#d(i){let t=i.target;c.UserBadges.instance().initialize().then(()=>{t.checked&&c.UserBadges.instance().recordAction(c.BadgeAction.RECEIVE_BADGES_SETTING_ENABLED)})}#l(i){let t=this.#e.isSyncActive?"chrome://settings/syncSetup/advanced":"chrome://settings/syncSetup";u.openInNewTab(t,!0),i.consume()}async#r(){if(!a.GdpClient.isGdpProfilesAvailable())return;let i=await a.GdpClient.GdpClient.instance().getProfile();i&&(this.#o=i.profile??void 0,this.#n=i.isEligible,this.requestUpdate())}};export{P as SyncSection};
//# sourceMappingURL=components.js.map
