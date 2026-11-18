var ft=Object.defineProperty;var W=(n,t)=>{for(var e in t)ft(n,e,{get:t[e],enumerable:!0})};var lt={};W(lt,{DEFAULT_VIEW:()=>et,LocationsSettingsTab:()=>V,locationsSettingsTabStyles:()=>$,renderEditorView:()=>Q,renderLocationDialog:()=>tt,validateAccuracy:()=>st,validateLatitude:()=>ot,validateLocale:()=>rt,validateLongitude:()=>nt,validateTimezoneId:()=>at,validateTitle:()=>it});import"../../ui/kit/kit.js";import"../../ui/components/lists/lists.js";import*as X from"../../core/common/common.js";import*as k from"../../core/i18n/i18n.js";import*as D from"../../core/sdk/sdk.js";import*as I from"../../ui/components/buttons/buttons.js";import*as T from"../../ui/legacy/legacy.js";import{Directives as bt,html as g,nothing as h,render as Et}from"../../ui/lit/lit.js";import*as Z from"../../ui/settings/settings.js";import*as J from"../../ui/visual_logging/visual_logging.js";var $=`devtools-button.add-locations-button:not(:first-child),
.add-locations-button{margin-bottom:var(--sys-size-5);border:none}devtools-list.locations-list,
.locations-list{margin-top:var(--sys-size-3);flex:auto;display:flex;border:var(--sys-size-1) solid var(--sys-color-divider)}.locations-list-item{padding:3px var(--sys-size-4);height:30px;display:flex;align-items:center;position:relative;flex:auto 1 1}.locations-list-text{white-space:nowrap;text-overflow:ellipsis;flex-basis:170px;user-select:none;color:var(--sys-color-on-surface);position:relative;overflow:hidden}.locations-list-title{text-align:start}.locations-list-title-text{overflow:hidden;flex:auto;white-space:nowrap;text-overflow:ellipsis}.locations-list-separator{flex:0 0 var(--sys-size-1);background-color:var(--sys-color-divider);height:30px;margin:0 var(--sys-size-3)}.locations-list-separator-invisible{visibility:hidden;height:100%!important}.locations-edit-row{display:flex;flex-direction:row;margin:var(--sys-size-4) 5px}.locations-edit-row input{width:100%;text-align:inherit}.locations-input-container{padding:var(--sys-size-1)}.settings-card-container-wrapper{scrollbar-gutter:stable;padding:var(--sys-size-8) 0;overflow:auto;position:absolute;inset:var(--sys-size-8) 0 0}.settings-card-container{display:flex;flex-direction:column;align-items:center;gap:var(--sys-size-9)}.location-dialog-content{padding:var(--sys-size-6);display:flex;flex-direction:column;gap:var(--sys-size-6);width:var(--sys-size-33);min-width:var(--sys-size-33)}.editor-grid{display:grid;grid-template-columns:1fr 1fr;gap:var(--sys-size-5) var(--sys-size-6)}.editor-field-full-width{grid-column:1/-1}.editor-field{display:flex;flex-direction:column;gap:var(--sys-size-2)}.editor-field-label{color:var(--sys-color-on-surface);font-size:var(--sys-size-6);font-weight:var(--ref-typeface-weight-medium)}.editor-field input{width:100%;box-sizing:border-box;padding:var(--sys-size-3) var(--sys-size-4);height:var(--sys-size-11);border:var(--sys-size-1) solid var(--sys-color-neutral-outline);border-radius:var(--sys-size-2);outline:none}.editor-field.has-error input{border-color:var(--sys-color-error)}.editor-field-error{color:var(--sys-color-error);font-size:var(--sys-size-6);overflow-wrap:break-word}.dialog-buttons{display:flex;justify-content:flex-end;gap:var(--sys-size-3);margin-top:var(--sys-size-3)}.dialog-header{display:flex;justify-content:space-between;align-items:center}.dialog-title{font-size:var(--sys-size-7);font-weight:var(--ref-typeface-weight-medium);color:var(--sys-color-on-surface)}.dialog-close-button{flex-shrink:0}
/*# sourceURL=${import.meta.resolve("./locationsSettingsTab.css")} */`;var{createRef:L,ref:x}=bt;var s={locations:"Locations",locationName:"Location name",lat:"Lat",long:"Long",timezoneId:"Timezone ID",locale:"Locale",latitude:"Latitude",longitude:"Longitude",accuracy:"Accuracy",locationNameCannotBeEmpty:"Location name can\u2019t be empty",locationNameMustBeLessThanS:"Location name must be less than {PH1} characters",latitudeMustBeANumber:"Latitude must be a number",latitudeMustBeGreaterThanOrEqual:"Latitude must be greater than or equal to {PH1}",latitudeMustBeLessThanOrEqualToS:"Latitude must be less than or equal to {PH1}",longitudeMustBeANumber:"Longitude must be a number",longitudeMustBeGreaterThanOr:"Longitude must be greater than or equal to {PH1}",longitudeMustBeLessThanOrEqualTo:"Longitude must be less than or equal to {PH1}",timezoneIdMustContainAlphabetic:"Timezone ID must contain alphabetic characters",localeMustContainAlphabetic:"Locale must contain alphabetic characters",accuracyMustBeANumber:"Accuracy must be a number",accuracyMustBeGreaterThanOrEqual:"Accuracy must be greater than or equal to {PH1}",addLocation:"Add location",editLocation:"Edit location",save:"Save",cancel:"Cancel",close:"Close"},yt=k.i18n.registerUIStrings("panels/sensors/LocationsSettingsTab.ts",s),l=k.i18n.getLocalizedString.bind(void 0,yt);function St(n){return g`
    <div class="locations-list-item">
      <div class="locations-list-text locations-list-title">
        <div class="locations-list-title-text" title=${n.title}>${n.title}</div>
      </div>
      <div class="locations-list-separator"></div>
      <div class="locations-list-text">${n.lat}</div>
      <div class="locations-list-separator"></div>
      <div class="locations-list-text">${n.long}</div>
      <div class="locations-list-separator"></div>
      <div class="locations-list-text">${n.timezoneId}</div>
      <div class="locations-list-separator"></div>
      <div class="locations-list-text">${n.locale}</div>
      <div class="locations-list-separator"></div>
      <div class="locations-list-text">${n.accuracy??D.EmulationModel.Location.DEFAULT_ACCURACY}</div>
    </div>`}function Q(n,t,e=!1){return e?g`
    <div class="editor-grid">
      <div class="editor-field editor-field-full-width ${t?.title?"has-error":""}">
        <label class="editor-field-label" for="location-title">${l(s.locationName)}</label>
        ${n.titleInput}
        ${t?.title?g`<div class="editor-field-error" role="alert">${t.title}</div>`:h}
      </div>
      <div class="editor-field ${t?.lat?"has-error":""}">
        <label class="editor-field-label" for="location-lat">${l(s.lat)}</label>
        ${n.latInput}
        ${t?.lat?g`<div class="editor-field-error" role="alert">${t.lat}</div>`:h}
      </div>
      <div class="editor-field ${t?.long?"has-error":""}">
        <label class="editor-field-label" for="location-long">${l(s.long)}</label>
        ${n.longInput}
        ${t?.long?g`<div class="editor-field-error" role="alert">${t.long}</div>`:h}
      </div>
      <div class="editor-field ${t?.timezoneId?"has-error":""}">
        <label class="editor-field-label" for="location-timezone">${l(s.timezoneId)}</label>
        ${n.timezoneIdInput}
        ${t?.timezoneId?g`<div class="editor-field-error" role="alert">${t.timezoneId}</div>`:h}
      </div>
      <div class="editor-field ${t?.locale?"has-error":""}">
        <label class="editor-field-label" for="location-locale">${l(s.locale)}</label>
        ${n.localeInput}
        ${t?.locale?g`<div class="editor-field-error" role="alert">${t.locale}</div>`:h}
      </div>
      <div class="editor-field editor-field-full-width ${t?.accuracy?"has-error":""}">
        <label class="editor-field-label" for="location-accuracy">${l(s.accuracy)}</label>
        ${n.accuracyInput}
        ${t?.accuracy?g`<div class="editor-field-error" role="alert">${t.accuracy}</div>`:h}
      </div>
    </div>
  `:g`
      <div class="locations-edit-row">
        <div class="locations-list-text locations-list-title">${l(s.locationName)}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text">${l(s.lat)}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text">${l(s.long)}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text">${l(s.timezoneId)}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text">${l(s.locale)}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text">${l(s.accuracy)}</div>
      </div>
      <div class="locations-edit-row">
        <div class="locations-list-text locations-list-title locations-input-container">${n.titleInput}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text locations-input-container">${n.latInput}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text locations-list-text-longitude locations-input-container">${n.longInput}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text locations-input-container">${n.timezoneIdInput}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text locations-input-container">${n.localeInput}</div>
        <div class="locations-list-separator locations-list-separator-invisible"></div>
        <div class="locations-list-text locations-input-container">${n.accuracyInput}</div>
      </div>
      ${t?g`
        <div class="locations-edit-row locations-error-row" role="alert">
          <div class="locations-list-text locations-list-title locations-error-cell">${t.title??h}</div>
          <div class="locations-list-separator locations-list-separator-invisible"></div>
          <div class="locations-list-text locations-error-cell">${t.lat??h}</div>
          <div class="locations-list-separator locations-list-separator-invisible"></div>
          <div class="locations-list-text locations-list-text-longitude locations-error-cell">${t.long??h}</div>
          <div class="locations-list-separator locations-list-separator-invisible"></div>
          <div class="locations-list-text locations-error-cell">${t.timezoneId??h}</div>
          <div class="locations-list-separator locations-list-separator-invisible"></div>
          <div class="locations-list-text locations-error-cell">${t.locale??h}</div>
          <div class="locations-list-separator locations-list-separator-invisible"></div>
          <div class="locations-list-text locations-error-cell">${t.accuracy??h}</div>
        </div>
      `:h}`}function tt(n){let t=L(),e=L(),i=L(),a=L(),o=L(),m=L(),r=()=>{let R=t.value?.value.trim()??"",O=e.value?.value.trim()??"",z=i.value?.value.trim()??"",B=a.value?.value.trim()??"",K=o.value?.value.trim()??"",U=m.value?.value.trim()??"",F=it(R),j=ot(O),_=nt(z),q=at(B),G=rt(K),Y=st(U);if(F||j||_||q||G||Y){n.onValidateErrors({title:F,lat:j,long:_,timezoneId:q,locale:G,accuracy:Y});return}n.onSave({title:R,lat:O?parseFloat(O):0,long:z?parseFloat(z):0,timezoneId:B,locale:K,accuracy:U?parseFloat(U):D.EmulationModel.Location.DEFAULT_ACCURACY})},E={titleInput:g`<input id="location-title" aria-label=${l(s.locationName)} type="text" placeholder=${l(s.locationName)} .value=${n.location.title} ${x(t)}>`,latInput:g`<input id="location-lat" aria-label=${l(s.lat)} type="text" placeholder=${l(s.latitude)} .value=${String(n.location.lat)} ${x(e)}>`,longInput:g`<input id="location-long" aria-label=${l(s.long)} type="text" placeholder=${l(s.longitude)} .value=${String(n.location.long)} ${x(i)}>`,timezoneIdInput:g`<input id="location-timezone" aria-label=${l(s.timezoneId)} type="text" placeholder=${l(s.timezoneId)} .value=${n.location.timezoneId} ${x(a)}>`,localeInput:g`<input id="location-locale" aria-label=${l(s.locale)} type="text" placeholder=${l(s.locale)} .value=${n.location.locale} ${x(o)}>`,accuracyInput:g`<input id="location-accuracy" aria-label=${l(s.accuracy)} type="text" placeholder=${l(s.accuracy)} .value=${String(n.location.accuracy??D.EmulationModel.Location.DEFAULT_ACCURACY)} ${x(m)}>`},ht=g`
    <style>${$}</style>
      <div class="location-dialog-content">
      <div class="dialog-header">
        <span class="dialog-title">${n.isNew?l(s.addLocation):l(s.editLocation)}</span>
        <devtools-button
          class="dialog-close-button"
          .iconName=${"cross"}
          .variant=${I.Button.Variant.ICON}
          .title=${l(s.close)}
          .jslogContext=${"dialog-close"}
          @click=${n.onCancel}
          aria-label=${l(s.close)}>
        </devtools-button>
      </div>
        ${Q(E,n.errors,!0)}
        <div class="dialog-buttons">
          <devtools-button
            class="save-button"
            .variant=${I.Button.Variant.PRIMARY}
            @click=${r}>
            ${l(s.save)}
          </devtools-button>
          <devtools-button
            class="cancel-button"
            .variant=${I.Button.Variant.OUTLINED}
            @click=${n.onCancel}>
            ${l(s.cancel)}
          </devtools-button>
        </div>
      </div>
  `;return g`
    <style>${$}</style>
    <devtools-widget
      class="location-dialog-widget"
      ${T.Widget.widget(T.Dialog.DialogWidget,{open:!0,jslogContext:"location-dialog",dialogStack:!0,content:ht})}
      @hidden=${n.onCancel}>
    </devtools-widget>
  `}var et=(n,t,e)=>{Et(g`
    <style>${$}</style>
    <div class="settings-card-container-wrapper">
      <div class="settings-card-container">
        <devtools-card .heading=${l(s.locations)}>
          <div>
            ${n.locations.length>0?g`
              <devtools-list
                class="locations-list square-corners"
                .editable=${!0}
                .deletable=${!0}
                @edit=${i=>n.onEditLocation(i.detail.index)}
                @delete=${i=>n.onRemoveLocation(i.detail.index)}>
                ${n.locations.map(i=>St(i))}
              </devtools-list>
            `:h}
          </div>
          <devtools-button
            class="add-locations-button"
            .variant=${I.Button.Variant.OUTLINED}
            .iconName=${"plus"}
            .jslogContext=${"emulation.add-location"}
            @click=${n.onAddLocation}>
            ${l(s.addLocation)}
          </devtools-button>
        </devtools-card>
      </div>
    </div>
    ${n.activeDialog?tt(n.activeDialog):h}
  `,e)},V=class extends T.Widget.VBox{customSetting;#i;#t;constructor(t,e=et){super(t,{jslog:`${J.pane("emulation-locations")}`,useShadowDom:!0}),this.#i=e,this.customSetting=X.Settings.Settings.instance().resolve(Z.EmulationSettings.emulationLocationsSettingDescriptor);let i=this.customSetting.get().map(o=>a(o,this.customSetting.defaultValue));function a(o,m){if(!o.title){let r=m.find(E=>E.lat===o.lat&&E.long===o.long&&E.timezoneId===o.timezoneId&&E.locale===o.locale);if(!r)console.error("Could not determine a location setting title");else return r}return o}this.customSetting.set(i),this.customSetting.addChangeListener(this.locationsUpdated,this)}wasShown(){super.wasShown(),this.locationsUpdated()}performUpdate(){let t;if(this.#t){let i=this.#t;t={location:i.location,isNew:i.isNew,errors:i.errors,onSave:a=>this.saveDialog(a),onCancel:()=>this.closeDialog(),onValidateErrors:a=>this.updateDialogErrors(a)}}let e={locations:this.customSetting.get(),onAddLocation:()=>this.addButtonClicked(),onEditLocation:i=>this.editLocationClicked(i),onRemoveLocation:i=>this.removeLocationClicked(i),activeDialog:t};this.#i(e,void 0,this.contentElement)}locationsUpdated(){this.requestUpdate()}addButtonClicked(){this.#t={location:{title:"",lat:0,long:0,timezoneId:"",locale:"",accuracy:D.EmulationModel.Location.DEFAULT_ACCURACY},isNew:!0},this.requestUpdate()}editLocationClicked(t){let i=this.customSetting.get()[t];i&&(this.#t={location:{...i},isNew:!1,index:t},this.requestUpdate())}removeLocationClicked(t){let e=this.customSetting.get();e.splice(t,1),this.customSetting.set(e)}saveDialog(t){if(!this.#t)return;let e=this.customSetting.get();this.#t.isNew?e.push(t):this.#t.index!==void 0&&(e[this.#t.index]=t),this.#t=void 0,this.customSetting.set(e)}closeDialog(){this.#t=void 0,this.requestUpdate()}updateDialogErrors(t){this.#t&&(this.#t.errors=t,this.requestUpdate())}};function it(n){let e=n.trim();return e.length?e.length>50?l(s.locationNameMustBeLessThanS,{PH1:50}):null:l(s.locationNameCannotBeEmpty)}function ot(n){let i=n.trim(),a=Number(i);return i?Number.isNaN(a)?l(s.latitudeMustBeANumber):a<-90?l(s.latitudeMustBeGreaterThanOrEqual,{PH1:-90}):a>90?l(s.latitudeMustBeLessThanOrEqualToS,{PH1:90}):null:null}function nt(n){let i=n.trim(),a=Number(i);return i?Number.isNaN(a)?l(s.longitudeMustBeANumber):a<-180?l(s.longitudeMustBeGreaterThanOr,{PH1:-180}):a>180?l(s.longitudeMustBeLessThanOrEqualTo,{PH1:180}):null:null}function at(n){let t=n.trim();return t===""||/[a-zA-Z]/.test(t)?null:l(s.timezoneIdMustContainAlphabetic)}function rt(n){let t=n.trim();return t===""||/[a-zA-Z]{2}/.test(t)?null:l(s.localeMustContainAlphabetic)}function st(n){let e=n.trim(),i=Number(e);return e?Number.isNaN(i)?l(s.accuracyMustBeANumber):i<0?l(s.accuracyMustBeGreaterThanOrEqual,{PH1:0}):null:null}var vt={};W(vt,{DeviceOrientationModificationSource:()=>pt,NonPresetOptions:()=>f,PressureOptions:()=>xt,SensorsView:()=>A,ShiftDragOrientationSpeed:()=>gt,ShowActionDelegate:()=>P});import*as y from"../../core/common/common.js";import*as ut from"../../core/host/host.js";import*as N from"../../core/i18n/i18n.js";import*as u from"../../core/sdk/sdk.js";import*as H from"../../ui/components/buttons/buttons.js";import*as S from"../../ui/geometry/geometry.js";import*as w from"../../ui/legacy/components/settings_ui/settings_ui.js";import*as b from"../../ui/legacy/legacy.js";import{Directives as v,html as C,render as dt}from"../../ui/lit/lit.js";import*as M from"../../ui/settings/settings.js";import*as p from"../../ui/visual_logging/visual_logging.js";import*as mt from"../mobile_throttling/mobile_throttling.js";var ct=`.sensors-view{padding:var(--sys-size-6);display:block}.sensors-view input{width:100%;max-width:120px;margin:-5px 10px 0 0;text-align:end}.sensors-view input[readonly]{background-color:var(--sys-color-neutral-container)}.sensors-view fieldset{border:none;padding:10px 0;flex:0 0 auto;margin:0}.sensors-view fieldset[disabled]{opacity:50%}.orientation-axis-input-container input{max-width:120px}.concurrency-details{margin:var(--sys-size-5) var(--sys-size-10);display:flex;align-items:center}.concurrency-details input{width:50px;margin:0}.concurrency-hidden{visibility:hidden}.sensors-view input:focus::-webkit-input-placeholder{color:transparent!important}.sensors-view select{width:200px}.sensors-group-title{width:var(--sys-size-19);line-height:var(--sys-typescale-body1-line-height)}.sensors-group{display:flex;flex-wrap:wrap;margin-bottom:10px}.manage-locations{margin-left:var(--sys-size-4)}.geo-fields{flex:2 0 200px}.latlong-group{display:flex;margin-bottom:10px}.latlong-title{width:70px}.timezone-error,
.locale-error{margin-left:10px;color:var(--legacy-input-validation-error)}.orientation-content{display:flex;flex-wrap:wrap}.orientation-fields{margin-right:10px}.orientation-stage{--override-gradient-color-1:var(--ref-palette-cyan95);--override-gradient-color-2:var(--ref-palette-cyan90);perspective:700px;perspective-origin:50% 50%;width:var(--sys-size-23);height:150px;background:linear-gradient(var(--override-gradient-color-1) 0%,var(--override-gradient-color-1) 64%,var(--override-gradient-color-2) 64%,var(--override-gradient-color-1) 100%);transition:0.2s ease opacity,0.2s ease filter;overflow:hidden;margin-bottom:10px}.theme-with-dark-background .orientation-stage,
:host-context(.theme-with-dark-background) .orientation-stage{--override-gradient-color-1:var(--ref-palette-cyan10);--override-gradient-color-2:var(--ref-palette-cyan30)}.orientation-stage.disabled{filter:grayscale();opacity:50%}.orientation-element,
.orientation-element::before,
.orientation-element::after{position:absolute;box-sizing:border-box;transform-style:preserve-3d;background:no-repeat;background-size:cover;backface-visibility:hidden}.orientation-box{width:62px;height:122px;inset:0;margin:auto;transform:rotate3d(1,0,0,90deg)}.orientation-layer{width:100%;height:100%;transform-style:preserve-3d}.orientation-box.is-animating,
.is-animating .orientation-layer{transition:transform 300ms cubic-bezier(0.4,0,0.2,1) 0ms}.orientation-front,
.orientation-back{width:62px;height:122px;border-radius:var(--sys-shape-corner-small)}.orientation-front{background-image:var(--image-file-accelerometer-front)}.orientation-back{transform:rotateY(180deg) translateZ(8px);background-image:var(--image-file-accelerometer-back)}.orientation-left,
.orientation-right{width:var(--sys-size-5);height:106px;top:var(--sys-size-5);background-position:center center}.orientation-left{left:calc(-1 * var(--sys-size-5));transform-origin:right center;transform:rotateY(-90deg);background-image:var(--image-file-accelerometer-left)}.orientation-right{right:calc(-1 * var(--sys-size-5));transform-origin:left center;transform:rotateY(90deg);background-image:var(--image-file-accelerometer-right)}.orientation-left::before,
.orientation-left::after,
.orientation-right::before,
.orientation-right::after{content:"";width:var(--sys-size-5);height:var(--sys-size-4)}.orientation-left::before,
.orientation-left::after{background-image:var(--image-file-accelerometer-left)}.orientation-right::before,
.orientation-right::after{background-image:var(--image-file-accelerometer-right)}.orientation-left::before,
.orientation-right::before{top:calc(-1 * var(--sys-size-4));transform-origin:center bottom;transform:rotateX(26deg);background-position:center top}.orientation-left::after,
.orientation-right::after{bottom:calc(-1 * var(--sys-size-4));transform-origin:center top;transform:rotateX(-25deg);background-position:center bottom}.orientation-top,
.orientation-bottom{width:50px;height:var(--sys-size-5);left:var(--sys-size-5);background-position:center center}.orientation-top{top:calc(-1 * var(--sys-size-5));transform-origin:center bottom;transform:rotateX(90deg);background-image:var(--image-file-accelerometer-top)}.orientation-bottom{bottom:calc(-1 * var(--sys-size-5));transform-origin:center top;transform:rotateX(-90deg);background-image:var(--image-file-accelerometer-bottom)}.orientation-top::before,
.orientation-top::after,
.orientation-bottom::before,
.orientation-bottom::after{content:"";width:var(--sys-size-5);height:var(--sys-size-5)}.orientation-top::before,
.orientation-top::after{background-image:var(--image-file-accelerometer-top)}.orientation-bottom::before,
.orientation-bottom::after{background-image:var(--image-file-accelerometer-bottom)}.orientation-top::before,
.orientation-bottom::before{left:calc(-1 * var(--sys-size-4));transform-origin:right center;transform:rotateY(-26deg);background-position:left center}.orientation-top::after,
.orientation-bottom::after{right:calc(-1 * var(--sys-size-4));transform-origin:left center;transform:rotateY(26deg);background-position:right center}.orientation-axis-input-container{margin-bottom:10px}.orientation-reset-button{min-width:var(--sys-size-19)}fieldset.device-orientation-override-section{margin:0;display:flex}.panel-section-separator{height:var(--sys-size-1);margin-bottom:var(--sys-size-9);margin-left:calc(-1 * var(--sys-size-6));margin-right:calc(-1 * var(--sys-size-6));background:var(--sys-color-divider)}button.text-button{margin:var(--sys-size-3) 0 0 10px}@media (forced-colors: active){.sensors-view fieldset[disabled]{opacity:100%}}.chrome-select-label{margin-bottom:var(--sys-size-8)}
/*# sourceURL=${import.meta.resolve("./sensors.css")} */`;var c={location:"Location",noOverride:"No override",overrides:"Overrides",manage:"Manage",manageTheListOfLocations:"Manage the list of locations",other:"Other\u2026",error:"Error",locationUnavailable:"Location unavailable",adjustWithMousewheelOrUpdownKeys:"Adjust with mousewheel or up/down keys. {PH1}: \xB110, Shift: \xB11, Alt: \xB10.01.",latitude:"Latitude",longitude:"Longitude",timezoneId:"Timezone ID",locale:"Locale",accuracy:"Accuracy",orientation:"Orientation",off:"Off",customOrientation:"Custom orientation",enableOrientationToRotate:"Enable orientation to rotate",shiftdragHorizontallyToRotate:"Shift+drag horizontally to rotate around the y-axis",deviceOrientationSetToAlphaSBeta:"Device orientation set to alpha: {PH1}, beta: {PH2}, gamma: {PH3}",reset:"Reset",resetDeviceOrientation:"Reset device orientation",forcesTouchInsteadOfClick:"Forces touch instead of click",forcesSelectedIdleStateEmulation:"Forces selected idle state emulation",forcesSelectedCpuPerformanceTierEmulation:"Forces CPU performance tier emulation",cpuPerformanceNoOverrideWithDefault:"No override ({PH1})",forcesSelectedPressureStateEmulation:"Forces selected pressure state emulation",presets:"Presets",portrait:"Portrait",portraitUpsideDown:"Portrait upside down",landscapeLeft:"Landscape left",landscapeRight:"Landscape right",displayUp:"Display up",displayDown:"Display down",alpha:"\u03B1 (alpha)",beta:"\u03B2 (beta)",gamma:"\u03B3 (gamma)"},Lt=N.i18n.registerUIStrings("panels/sensors/SensorsView.ts",c),d=N.i18n.getLocalizedString.bind(void 0,Lt),A=class extends b.Widget.VBox{#i;#t;#e;#c;fieldsetElement;timezoneError;locationSelectElement;latitudeInput;longitudeInput;timezoneInput;localeInput;accuracyInput;localeError;accuracyError;deviceOrientationSetting;deviceOrientation;deviceOrientationOverrideEnabled;deviceOrientationFieldset;stageElement;orientationSelectElement;alphaElement;betaElement;gammaElement;orientationLayer;boxMatrix;mouseDownVector;originalBoxMatrix;#n;#o;constructor(){super({jslog:`${p.panel("sensors").track({resize:!0})}`,useShadowDom:!0}),this.registerRequiredCSS(ct),this.contentElement.classList.add("sensors-view"),this.#n=u.CPUThrottlingManager.CPUThrottlingManager.instance(),this.#i=y.Settings.Settings.instance().createSetting("emulation.location-override",""),this.#t=u.EmulationModel.Location.parseSetting(this.#i.get()),this.#e=!1,this.#c=this.contentElement.createChild("section","sensors-group");let t=y.Settings.Settings.instance().resolve(M.EmulationSettings.emulationLocationsSettingDescriptor);this.renderLocationSection(this.#t,t),t.addChangeListener(()=>this.renderLocationSection(this.#t,t)),this.createPanelSeparator(),this.deviceOrientationSetting=y.Settings.Settings.instance().createSetting("emulation.device-orientation-override",""),this.deviceOrientation=u.EmulationModel.DeviceOrientation.parseSetting(this.deviceOrientationSetting.get()),this.deviceOrientationOverrideEnabled=!1,this.createDeviceOrientationSection(),this.createPanelSeparator(),this.appendTouchControl(),this.createPanelSeparator(),this.appendIdleEmulator(),this.createPanelSeparator(),this.createHardwareConcurrencySection(),this.createPanelSeparator(),this.createPressureSection(),this.createPanelSeparator(),this.createCPUPerformanceSection(),this.createPanelSeparator()}createPanelSeparator(){this.contentElement.createChild("div").classList.add("panel-section-separator")}renderLocationSection(t,e){let i=e.get(),a=0;if(this.#e)if(t.unavailable)a=i.length+2;else{a=i.length+1;for(let[r,E]of i.entries())if(t.latitude===E.lat&&t.longitude===E.long&&t.timezoneId===E.timezoneId&&t.locale===E.locale){a=r+1;break}}let o=ut.Platform.isMac()?"\u2318":"Ctrl",m=d(c.adjustWithMousewheelOrUpdownKeys,{PH1:o});this.#c.setAttribute("jslog",`${p.section("location")}`),dt(C`
      <label class="sensors-group-title" id="location-select-label" for="location-select">${d(c.location)}</label>
      <div class="geo-fields">
        <select
          id="location-select"
          ${v.ref(r=>{r&&(this.locationSelectElement=r)})}
          .selectedIndex=${a}
          @change=${this.#p.bind(this)}
          jslog=${p.dropDown().track({change:!0})}
        >
          <option value=${f.NoOverride} jslog=${p.item("no-override")}>${d(c.noOverride)}</option>
          <optgroup label=${d(c.overrides)}>
            ${i.map(r=>C`
              <option value=${JSON.stringify(r)} jslog=${p.item("custom")}>${r.title}</option>
            `)}
          </optgroup>
          <option value=${f.Custom} jslog=${p.item("other")}>${d(c.other)}</option>
          <optgroup label=${d(c.error)}>
            <option value=${f.Unavailable} jslog=${p.item("unavailable")}>${d(c.locationUnavailable)}</option>
          </optgroup>
        </select>
        <devtools-button
          .variant=${H.Button.Variant.OUTLINED}
          class="manage-locations"
          @click=${()=>y.Revealer.reveal(e)}
          aria-label=${d(c.manageTheListOfLocations)}
          jslog=${p.action("sensors.manage-locations").track({click:!0})}
        >
          ${d(c.manage)}
        </devtools-button>
        <fieldset
          id="location-override-section"
          ?disabled=${!this.#e}
          ${v.ref(r=>{r&&(this.fieldsetElement=r)})}
        >
          <div class="latlong-group">
            <!-- @ts-ignore -->
            <input
              id="latitude-input"
              type="number"
              min="-90"
              max="90"
              step="any"
              required
              .value=${String(t.latitude)}
              name="latitude"
              title=${m}
              jslog=${p.textField("latitude").track({change:!0})}
              ${v.ref(r=>{r&&(this.latitudeInput=r)})}
              @change=${this.#r.bind(this)}
              @keydown=${this.#s.bind(this)}
              @focus=${this.#l.bind(this)}
            >
            <label class="latlong-title" for="latitude-input">${d(c.latitude)}</label>
          </div>
          <div class="latlong-group">
            <!-- @ts-ignore -->
            <input
              id="longitude-input"
              type="number"
              min="-180"
              max="180"
              step="any"
              required
              .value=${String(t.longitude)}
              name="longitude"
              title=${m}
              jslog=${p.textField("longitude").track({change:!0})}
              ${v.ref(r=>{r&&(this.longitudeInput=r)})}
              @change=${this.#r.bind(this)}
              @keydown=${this.#s.bind(this)}
              @focus=${this.#l.bind(this)}
            >
            <label class="latlong-title" for="longitude-input">${d(c.longitude)}</label>
          </div>
          <div class="latlong-group">
            <input
              id="timezone-input"
              type="text"
              pattern=".*[a-zA-Z].*"
              .value=${t.timezoneId}
              name="timezone"
              jslog=${p.textField("timezone").track({change:!0})}
              ${v.ref(r=>{r&&(this.timezoneInput=r)})}
              @change=${this.#r.bind(this)}
              @keydown=${this.#s.bind(this)}
              @focus=${this.#l.bind(this)}
            >
            <label class="timezone-title" for="timezone-input">${d(c.timezoneId)}</label>
            <div class="timezone-error" ${v.ref(r=>{r&&(this.timezoneError=r)})}></div>
          </div>
          <div class="latlong-group">
            <input
              id="locale-input"
              type="text"
              pattern=".*[a-zA-Z]{2}.*"
              .value=${t.locale}
              name="locale"
              jslog=${p.textField("locale").track({change:!0})}
              ${v.ref(r=>{r&&(this.localeInput=r)})}
              @change=${this.#r.bind(this)}
              @keydown=${this.#s.bind(this)}
              @focus=${this.#l.bind(this)}
            >
            <label class="locale-title" for="locale-input">${d(c.locale)}</label>
            <div class="locale-error" ${v.ref(r=>{r&&(this.localeError=r)})}></div>
          </div>
          <div class="latlong-group">
            <!-- @ts-ignore -->
            <input
              id="accuracy-input"
              type="number"
              min="0"
              step="any"
              .value=${String(t.accuracy||u.EmulationModel.Location.DEFAULT_ACCURACY)}
              name="accuracy"
              jslog=${p.textField("accuracy").track({change:!0})}
              ${v.ref(r=>{r&&(this.accuracyInput=r)})}
              @change=${this.#r.bind(this)}
              @keydown=${this.#s.bind(this)}
              @focus=${this.#l.bind(this)}
            >
            <label class="accuracy-title" for="accuracy-input">${d(c.accuracy)}</label>
            <div class="accuracy-error" ${v.ref(r=>{r&&(this.accuracyError=r)})}></div>
          </div>
        </fieldset>
      </div>
    `,this.#c)}#p(){this.fieldsetElement.disabled=!1,this.timezoneError.textContent="",this.accuracyError.textContent="";let t=this.locationSelectElement.options[this.locationSelectElement.selectedIndex].value;if(t===f.NoOverride)this.#e=!1,this.clearFieldsetElementInputs(),this.fieldsetElement.disabled=!0;else if(t===f.Custom){this.#e=!0;let e=u.EmulationModel.Location.parseUserInput(this.latitudeInput.value.trim(),this.longitudeInput.value.trim(),this.timezoneInput.value.trim(),this.localeInput.value.trim(),this.accuracyInput.value.trim());if(!e)return;this.#t=e}else if(t===f.Unavailable)this.#e=!0,this.#t=new u.EmulationModel.Location(0,0,"","",u.EmulationModel.Location.DEFAULT_ACCURACY,!0);else{this.#e=!0;let e=JSON.parse(t);this.#t=new u.EmulationModel.Location(e.lat,e.long,e.timezoneId,e.locale,e.accuracy||u.EmulationModel.Location.DEFAULT_ACCURACY,!1),this.latitudeInput.value=e.lat,this.longitudeInput.value=e.long,this.timezoneInput.value=e.timezoneId,this.localeInput.value=e.locale,this.accuracyInput.value=String(e.accuracy||u.EmulationModel.Location.DEFAULT_ACCURACY)}this.applyLocation(),t===f.Custom&&this.latitudeInput.focus()}#r(t){t.currentTarget.checkValidity()&&this.applyLocationUserInput()}#s(t){let e=t.currentTarget;if(t.key==="Enter"){e.checkValidity()&&this.applyLocationUserInput(),t.preventDefault();return}if(!(e===this.latitudeInput||e===this.longitudeInput||e===this.accuracyInput))return;let a=e===this.accuracyInput?1:.1,o=b.UIUtils.modifiedFloatNumber(parseFloat(e.value),t,a);if(o===null)return;let m=e.value;e.value=String(o),e.checkValidity()?this.applyLocationUserInput():e.value=m,t.preventDefault()}#l(t){t.currentTarget.select()}applyLocationUserInput(){let t=u.EmulationModel.Location.parseUserInput(this.latitudeInput.value.trim(),this.longitudeInput.value.trim(),this.timezoneInput.value.trim(),this.localeInput.value.trim(),this.accuracyInput.value.trim());t&&(this.timezoneError.textContent="",this.accuracyError.textContent="",this.setSelectElementLabel(this.locationSelectElement,f.Custom),this.#t=t,this.applyLocation())}applyLocation(){this.#e?this.#i.set(this.#t.toSetting()):this.#i.set("");for(let t of u.TargetManager.TargetManager.instance().models(u.EmulationModel.EmulationModel))t.emulateLocation(this.#e?this.#t:null).catch(e=>{switch(e.type){case"emulation-set-timezone":{this.timezoneError.textContent=e.message;break}case"emulation-set-locale":{this.localeError.textContent=e.message;break}case"emulation-set-accuracy":{this.accuracyError.textContent=e.message;break}}})}clearFieldsetElementInputs(){this.latitudeInput.value="0",this.longitudeInput.value="0",this.timezoneInput.value="",this.localeInput.value="",this.accuracyInput.value=u.EmulationModel.Location.DEFAULT_ACCURACY.toString()}createDeviceOrientationSection(){let t=this.contentElement.createChild("section","sensors-group");t.setAttribute("jslog",`${p.section("device-orientation")}`);let e={title:d(c.off),orientation:f.NoOverride,jslogContext:"off"},i={title:d(c.customOrientation),orientation:f.Custom},a=[{title:d(c.presets),value:[{title:d(c.portrait),orientation:"[0, 90, 0]",jslogContext:"portrait"},{title:d(c.portraitUpsideDown),orientation:"[180, -90, 0]",jslogContext:"portrait-upside-down"},{title:d(c.landscapeLeft),orientation:"[90, 0, -90]",jslogContext:"landscape-left"},{title:d(c.landscapeRight),orientation:"[90, -180, -90]",jslogContext:"landscape-right"},{title:d(c.displayUp),orientation:"[0, 0, 0]",jslogContext:"display-up"},{title:d(c.displayDown),orientation:"[0, -180, 0]",jslogContext:"displayUp-down"}]}];dt(C`
        <label class="sensors-group-title" for="orientation-select">${d(c.orientation)}</label>
        <div class="orientation-content">
          <div class="orientation-fields">
            <select
              id="orientation-select"
              ${v.ref(o=>{o&&(this.orientationSelectElement=o)})}
              @change=${this.orientationSelectChanged.bind(this)}
              jslog=${p.dropDown().track({change:!0})}
            >
              <option value=${e.orientation} jslog=${p.item(e.jslogContext)}>${e.title}</option>
              <option value=${i.orientation} jslog=${p.item("custom")}>${i.title}</option>
              ${a.map(o=>C`
                <optgroup label=${o.title}>
                  ${o.value.map(m=>C`
                    <option value=${m.orientation} jslog=${p.item(m.jslogContext)}>${m.title}</option>
                  `)}
                </optgroup>
              `)}
            </select>
            <fieldset
              class="device-orientation-override-section"
              ${v.ref(o=>{o&&(this.deviceOrientationFieldset=o)})}
            >
              <div class="orientation-inputs-cell">
                <div class="orientation-axis-input-container">
                  <!-- @ts-ignore -->
                  <input
                    id="alpha-input"
                    type="number"
                    min="0"
                    max="359.9999"
                    step="any"
                    required
                    ${v.ref(o=>{o&&(this.alphaElement=o)})}
                    @change=${this.#d.bind(this)}
                    @keydown=${this.#u.bind(this)}
                    @focus=${this.#m.bind(this)}
                  >
                  <label for="alpha-input">${d(c.alpha)}</label>
                </div>
                <div class="orientation-axis-input-container">
                  <!-- @ts-ignore -->
                  <input
                    id="beta-input"
                    type="number"
                    min="-180"
                    max="179.9999"
                    step="any"
                    required
                    ${v.ref(o=>{o&&(this.betaElement=o)})}
                    @change=${this.#d.bind(this)}
                    @keydown=${this.#u.bind(this)}
                    @focus=${this.#m.bind(this)}
                  >
                  <label for="beta-input">${d(c.beta)}</label>
                </div>
                <div class="orientation-axis-input-container">
                  <!-- @ts-ignore -->
                  <input
                    id="gamma-input"
                    type="number"
                    min="-90"
                    max="89.9999"
                    step="any"
                    required
                    ${v.ref(o=>{o&&(this.gammaElement=o)})}
                    @change=${this.#d.bind(this)}
                    @keydown=${this.#u.bind(this)}
                    @focus=${this.#m.bind(this)}
                  >
                  <label for="gamma-input">${d(c.gamma)}</label>
                </div>
                <devtools-button
                  .variant=${H.Button.Variant.OUTLINED}
                  class="orientation-reset-button"
                  type="reset"
                  aria-label=${d(c.resetDeviceOrientation)}
                  @click=${this.resetDeviceOrientation.bind(this)}
                  jslog=${p.action("sensors.reset-device-orientiation").track({click:!0})}
                >
                  ${d(c.reset)}
                </devtools-button>
              </div>
            </fieldset>
          </div>
          <div
            class="orientation-stage"
            jslog=${p.preview().track({drag:!0})}
            ${v.ref(o=>{o&&!this.stageElement&&(this.stageElement=o,b.UIUtils.installDragHandle(this.stageElement,this.onBoxDragStart.bind(this),m=>{this.onBoxDrag(m)},null,"-webkit-grabbing","-webkit-grab"))})}
          >
            <div class="orientation-layer" ${v.ref(o=>{o&&(this.orientationLayer=o)})}>
              <section
                class="orientation-box orientation-element"
              >
                <section class="orientation-front orientation-element"></section>
                <section class="orientation-top orientation-element"></section>
                <section class="orientation-back orientation-element"></section>
                <section class="orientation-left orientation-element"></section>
                <section class="orientation-right orientation-element"></section>
                <section class="orientation-bottom orientation-element"></section>
              </section>
            </div>
          </div>
        </div>
      `,t),this.enableOrientationFields(!0),this.setBoxOrientation(this.deviceOrientation,!1),this.alphaElement.value=String(this.deviceOrientation.alpha),this.betaElement.value=String(this.deviceOrientation.beta),this.gammaElement.value=String(this.deviceOrientation.gamma)}createPressureSection(){let t=this.contentElement.createChild("div","pressure-section"),e=w.SettingsUI.createControlForSetting(y.Settings.Settings.instance().resolve(u.SDKSettings.cpuPressureSettingDescriptor),d(c.forcesSelectedPressureStateEmulation));e&&t.appendChild(e)}createCPUPerformanceSection(){let t=this.contentElement.createChild("div","cpu-performance-section"),e=w.SettingsUI.createControlForSetting(y.Settings.Settings.instance().resolve(u.SDKSettings.cpuPerformanceSettingDescriptor),d(c.forcesSelectedCpuPerformanceTierEmulation));if(e){t.appendChild(e);let i=e.querySelector('select option[value="no-override"]');i?(this.#o=i,this.#a()):this.#o=void 0}}wasShown(){super.wasShown(),this.#o&&(this.#n.addEventListener(u.CPUThrottlingManager.Events.CPU_PERFORMANCE_TIER_CHANGED,this.#a,this),this.#n.addEventListener(u.CPUThrottlingManager.Events.RATE_CHANGED,this.#a,this),this.#a())}willHide(){super.willHide(),this.#o&&(this.#n.removeEventListener(u.CPUThrottlingManager.Events.CPU_PERFORMANCE_TIER_CHANGED,this.#a,this),this.#n.removeEventListener(u.CPUThrottlingManager.Events.RATE_CHANGED,this.#a,this))}#a(){if(!this.#o)return;let t=M.SettingUIRegistration.resolve(u.SDKSettings.cpuPerformanceSettingDescriptor).options,e=o=>{let m=t.find(r=>r.value===o);return m?m.title:""},i=o=>`Tier ${u.CPUThrottlingManager.tierToNumber(o)}: ${o.toUpperCase()}`,a=this.#n.calculatedCPUPerformanceTier();if(a!==void 0){let o=e(a)||i(a);this.#o.text=d(c.cpuPerformanceNoOverrideWithDefault,{PH1:o})}else this.#o.text=e("no-override")||"No override"}enableOrientationFields(t){t?(this.deviceOrientationFieldset.disabled=!0,this.stageElement.classList.add("disabled"),b.Tooltip.Tooltip.install(this.stageElement,d(c.enableOrientationToRotate))):(this.deviceOrientationFieldset.disabled=!1,this.stageElement.classList.remove("disabled"),b.Tooltip.Tooltip.install(this.stageElement,d(c.shiftdragHorizontallyToRotate)))}orientationSelectChanged(){let t=this.orientationSelectElement.options[this.orientationSelectElement.selectedIndex].value;if(this.enableOrientationFields(!1),t===f.NoOverride)this.deviceOrientationOverrideEnabled=!1,this.enableOrientationFields(!0),this.applyDeviceOrientation();else if(t===f.Custom)this.deviceOrientationOverrideEnabled=!0,this.resetDeviceOrientation(),this.alphaElement.focus();else{let e=JSON.parse(t);this.deviceOrientationOverrideEnabled=!0,this.deviceOrientation=new u.EmulationModel.DeviceOrientation(e[0],e[1],e[2]),this.setDeviceOrientation(this.deviceOrientation,"selectPreset")}}applyDeviceOrientation(){this.deviceOrientationOverrideEnabled&&this.deviceOrientationSetting.set(this.deviceOrientation.toSetting());for(let t of u.TargetManager.TargetManager.instance().models(u.EmulationModel.EmulationModel))t.emulateDeviceOrientation(this.deviceOrientationOverrideEnabled?this.deviceOrientation:null)}setSelectElementLabel(t,e){let i=Array.prototype.map.call(t.options,a=>a.value);t.selectedIndex=i.indexOf(e)}applyDeviceOrientationUserInput(){this.setDeviceOrientation(u.EmulationModel.DeviceOrientation.parseUserInput(this.alphaElement.value.trim(),this.betaElement.value.trim(),this.gammaElement.value.trim()),"userInput"),this.setSelectElementLabel(this.orientationSelectElement,f.Custom)}resetDeviceOrientation(){this.setDeviceOrientation(new u.EmulationModel.DeviceOrientation(0,90,0),"resetButton"),this.setSelectElementLabel(this.orientationSelectElement,"[0, 90, 0]")}setDeviceOrientation(t,e){if(!t)return;function i(o){return Math.round(o*1e4)/1e4}e!=="userInput"&&(this.alphaElement.value=String(i(t.alpha)),this.betaElement.value=String(i(t.beta)),this.gammaElement.value=String(i(t.gamma)));let a=e!=="userDrag";this.setBoxOrientation(t,a),this.deviceOrientation=t,this.applyDeviceOrientation(),b.ARIAUtils.LiveAnnouncer.alert(d(c.deviceOrientationSetToAlphaSBeta,{PH1:t.alpha,PH2:t.beta,PH3:t.gamma}))}#d(t){t.currentTarget.checkValidity()&&this.applyDeviceOrientationUserInput()}#u(t){let e=t.currentTarget;if(t.key==="Enter"){e.checkValidity()&&this.applyDeviceOrientationUserInput(),t.preventDefault();return}let i=b.UIUtils.modifiedFloatNumber(parseFloat(e.value),t,1);if(i===null)return;let a=e.value;e.value=String(i),e.checkValidity()?this.applyDeviceOrientationUserInput():e.value=a,t.preventDefault()}#m(t){t.currentTarget.select()}setBoxOrientation(t,e){e?this.stageElement.classList.add("is-animating"):this.stageElement.classList.remove("is-animating");let{alpha:i,beta:a,gamma:o}=t;this.boxMatrix=new DOMMatrixReadOnly().rotate(0,0,i).rotate(a,0,0).rotate(0,o,0),this.orientationLayer.style.transform=`rotateY(${i}deg) rotateX(${-a}deg) rotateZ(${o}deg)`}onBoxDrag(t){let e=this.calculateRadiusVector(t.x,t.y);if(!e||!this.mouseDownVector)return!0;t.consume(!0);let i,a;t.shiftKey?(i=new S.Vector(0,0,1),a=(e.x-this.mouseDownVector.x)*gt):(i=S.crossProduct(this.mouseDownVector,e),a=S.calculateAngle(this.mouseDownVector,e));let o=new DOMMatrixReadOnly().rotateAxisAngle(-i.x,i.z,i.y,a).multiply(this.originalBoxMatrix),m=S.EulerAngles.fromDeviceOrientationRotationMatrix(o),r=new u.EmulationModel.DeviceOrientation(m.alpha,m.beta,m.gamma);return this.setDeviceOrientation(r,"userDrag"),this.setSelectElementLabel(this.orientationSelectElement,f.Custom),!1}onBoxDragStart(t){return!this.deviceOrientationOverrideEnabled||(this.mouseDownVector=this.calculateRadiusVector(t.x,t.y),this.originalBoxMatrix=this.boxMatrix,!this.mouseDownVector)?!1:(t.consume(!0),!0)}calculateRadiusVector(t,e){let i=this.stageElement.getBoundingClientRect(),a=Math.max(i.width,i.height)/2,o=(t-i.left-i.width/2)/a,m=(e-i.top-i.height/2)/a,r=o*o+m*m;return r>.5?new S.Vector(o,m,.5/Math.sqrt(r)):new S.Vector(o,m,Math.sqrt(1-r))}appendTouchControl(){let t=this.contentElement.createChild("div","touch-section"),e=w.SettingsUI.createControlForSetting(y.Settings.Settings.instance().resolve(u.SDKSettings.touchSettingDescriptor),d(c.forcesTouchInsteadOfClick));e&&t.appendChild(e)}appendIdleEmulator(){let t=this.contentElement.createChild("div","idle-section"),e=w.SettingsUI.createControlForSetting(y.Settings.Settings.instance().resolve(u.SDKSettings.idleDetectionSettingDescriptor),d(c.forcesSelectedIdleStateEmulation));e&&t.appendChild(e)}createHardwareConcurrencySection(){let t=this.contentElement.createChild("div","concurrency-section"),{checkbox:e,numericInput:i,reset:a,warning:o}=mt.ThrottlingManager.throttlingManager().createHardwareConcurrencySelector(),m=document.createElement("div");m.classList.add("concurrency-details"),m.append(i.element,a.element,o.element),t.append(e,m)}},pt=(a=>(a.USER_INPUT="userInput",a.USER_DRAG="userDrag",a.RESET_BUTTON="resetButton",a.SELECT_PRESET="selectPreset",a))(pt||{}),xt={NoOverride:"no-override",Nominal:"nominal",Fair:"fair",Serious:"serious",Critical:"critical"},f={NoOverride:"noOverride",Custom:"custom",Unavailable:"unavailable"},P=class{handleAction(t,e){return b.ViewManager.ViewManager.instance().showView("sensors"),!0}},gt=16;export{lt as LocationsSettingsTab,vt as SensorsView};
//# sourceMappingURL=sensors.js.map
