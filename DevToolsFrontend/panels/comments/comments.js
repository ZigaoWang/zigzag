var $=Object.defineProperty;var M=(o,s)=>{for(var e in s)$(o,e,{get:s[e],enumerable:!0})};var z={};M(z,{CommentsPane:()=>y,DEFAULT_VIEW:()=>k});import"../../ui/components/spinners/spinners.js";import"../../ui/components/tooltips/tooltips.js";import*as w from"../../core/common/common.js";import*as g from"../../core/i18n/i18n.js";import*as m from"../../models/comment_manager/comment_manager.js";import*as p from"../../ui/components/buttons/buttons.js";import*as b from"../../ui/legacy/legacy.js";import*as v from"../../ui/lit/lit.js";import*as r from"../../ui/visual_logging/visual_logging.js";import*as h from"../common/common.js";var T=`@scope to (devtools-widget > *){.comments-container{display:flex;flex-direction:column;height:100%;width:100%;overflow:hidden}.comments-toolbar{display:flex;align-items:center;justify-content:space-between;height:var(--sys-size-13);padding:0 var(--sys-size-5);border-bottom:var(--sys-size-1) solid var(--sys-color-divider);background-color:var(--sys-color-surface1);flex-shrink:0}.toolbar-left{display:flex;align-items:center;height:100%;gap:var(--sys-size-8);padding-left:var(--sys-size-3)}.tab-button{position:relative;display:flex;align-items:center;height:100%;padding:0 var(--sys-size-2);border:none;background:transparent;color:var(--sys-color-on-surface-subtle);font-size:var(--sys-typescale-body4-size);font-weight:var(--ref-typeface-weight-regular);cursor:pointer}.tab-button:hover{color:var(--sys-color-on-surface)}.tab-button:focus-visible{outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:calc(-1 * var(--sys-size-2))}.tab-button.active{color:var(--sys-color-primary);font-weight:var(--ref-typeface-weight-bold)}.tab-button.active::after{content:"";position:absolute;bottom:0;left:0;right:0;height:var(--sys-size-2);background-color:var(--sys-color-primary);border-radius:var(--sys-shape-corner-full) var(--sys-shape-corner-full) 0 0}.toolbar-button{display:flex;align-items:center;justify-content:center;width:var(--sys-size-11);height:var(--sys-size-11);padding:0;border:none;background:transparent;border-radius:var(--sys-shape-corner-extra-small);cursor:pointer;color:var(--sys-color-on-surface-subtle)}.toolbar-button:hover{background-color:var(--sys-color-state-hover-on-subtle);color:var(--sys-color-on-surface)}.toolbar-button:active{background-color:var(--sys-color-state-ripple-neutral-on-subtle)}.comments-list{flex:1;overflow-y:auto;margin:0;padding:0;list-style:none}.comment-thread-item{display:flex;align-items:center;gap:var(--sys-size-5);padding:var(--sys-size-5) var(--sys-size-8);border-bottom:var(--sys-size-1) solid var(--sys-color-divider);cursor:pointer;transition:background-color var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized)}.comment-thread-item:hover{background-color:var(--sys-color-state-hover-on-subtle)}.comment-thread-item:focus-visible{background-color:var(--sys-color-state-hover-on-subtle);outline:var(--sys-size-2) solid var(--sys-color-state-focus-ring);outline-offset:calc(-1 * var(--sys-size-2))}.comment-pin-badge{width:var(--sys-size-9);height:var(--sys-size-9);margin-right:var(--sys-size-2);border-radius:var(--sys-shape-corner-full) var(--sys-shape-corner-full) var(--sys-shape-corner-full) var(--sys-shape-corner-extra-small);background-color:var(--sys-color-primary);flex-shrink:0}.comment-thread-item.orphaned .comment-pin-badge{background-color:var(--sys-color-surface-variant);color:var(--sys-color-on-surface-subtle)}.anchor-chip{display:flex;height:calc(var(--sys-size-8) + var(--sys-size-2));padding:var(--sys-size-2) var(--sys-size-4) var(--sys-size-2) var(--sys-size-3);align-items:center;border-radius:var(--sys-shape-corner-extra-small);border:var(--sys-size-1) solid var(--sys-color-divider);background:var(--sys-color-surface2);font-family:var(--source-code-font-family);font-size:var(--monospace-font-size);color:var(--sys-color-token-tag);overflow:hidden;max-width:var(--sys-size-24);min-width:0;flex-shrink:0;pointer-events:none}.anchor-chip.orphaned{border-style:dashed;border-color:var(--sys-color-neutral-outline);background:transparent;color:var(--sys-color-state-disabled);gap:var(--sys-size-3)}.anchor-chip.orphaned .anchor-chip-text{color:var(--sys-color-state-disabled)}.orphaned-label{flex-shrink:0;color:var(--sys-color-on-surface-subtle);font-family:var(--default-font-family);font-size:var(--sys-typescale-body5-size);font-style:italic}.anchor-chip devtools-widget,
  .anchor-chip-text{display:block;flex:0 1 auto;min-width:0;overflow:hidden;white-space:nowrap;text-overflow:ellipsis}.comment-text{flex:1;font-size:var(--sys-typescale-body4-size);line-height:var(--sys-typescale-body4-line-height);color:var(--sys-color-on-surface);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.thread-status-working{display:flex;align-items:center;gap:var(--sys-size-4);color:var(--sys-color-on-surface-subtle);font-size:var(--sys-typescale-body4-size);line-height:var(--sys-typescale-body4-line-height);font-weight:var(--ref-typeface-weight-medium);white-space:nowrap}.comments-empty-state{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;color:var(--sys-color-on-surface-subtle);font-size:var(--sys-typescale-body3-size);padding:var(--sys-size-13);text-align:center}.comments-footer{display:flex;align-items:center;justify-content:flex-end;gap:var(--sys-size-5);padding:var(--sys-size-5) var(--sys-size-8);border-top:var(--sys-size-1) solid var(--sys-color-divider);flex-shrink:0}.info-icon{color:var(--sys-color-on-surface-subtle);cursor:pointer}.info-tooltip-container{max-width:var(--sys-size-28);padding:var(--sys-size-4) var(--sys-size-5)}.send-agent-button{background-color:var(--sys-color-primary);color:var(--sys-color-on-primary);border:none;border-radius:var(--sys-shape-corner-full);padding:var(--sys-size-4) var(--sys-size-8);font-size:var(--sys-typescale-body4-size);font-weight:var(--ref-typeface-weight-medium);cursor:pointer;transition:background-color var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized),box-shadow var(--sys-motion-duration-short4) var(--sys-motion-easing-emphasized)}.send-agent-button:hover{background-color:var(--sys-color-primary-bright);box-shadow:var(--sys-elevation-level1)}.send-agent-button:disabled{background-color:var(--sys-color-state-disabled-container);color:var(--sys-color-state-disabled);cursor:default;box-shadow:none}}
/*# sourceURL=${import.meta.resolve("./commentsPane.css")} */`;var{html:l,render:E,Directives:{repeat:S}}=v,{widget:V}=b.Widget,{computeCommentTitle:D}=h.CommentThreadWidget,n={clearComments:"Clear all comments",noQueuedComments:"No queued comments. Add comments on elements in DevTools to send to your AI coding agent.",noSentComments:"No sent comments. Send comments to your AI coding agent to see them here.",deleteComment:"Delete comment",sendToAgent:"Send to Agent",working:"Working",seeResponse:"See response",queued:"Queued",sent:"Sent",removed:"removed"},L={inputDisclaimer:"Comment strings, DOM hierarchy snippets, tracked CSS and DOM changes, Visual Element (VE) paths and signatures, and tracked presenter changes are sent to the connected third-party agent to assist with debugging and code updates"},A=g.i18n.registerUIStrings("panels/comments/CommentsPane.ts",n),i=g.i18n.getLocalizedString.bind(void 0,A),I=g.i18n.lockedString;function q(o,s){switch(o.status){case"SENT_TO_AGENT":return l`
        <div class="thread-status-working">
          <devtools-spinner></devtools-spinner>
          <span>${i(n.working)}</span>
        </div>
      `;case"RESOLVED":return l`
        <devtools-button
          .data=${{variant:p.Button.Variant.TEXT,jslogContext:"comments-see-response"}}
          @keydown=${e=>{(e.key==="Enter"||e.key===" ")&&e.stopPropagation()}}
        >${i(n.seeResponse)}</devtools-button>
      `;case"ACTIVE":return l`
        <devtools-button
          .data=${{variant:p.Button.Variant.ICON,iconName:"bin",title:i(n.deleteComment),jslogContext:"delete"}}
          @click=${e=>{e.stopPropagation(),s(o.id)}}
          @keydown=${e=>{(e.key==="Enter"||e.key===" ")&&e.stopPropagation()}}
        ></devtools-button>
      `;default:return v.nothing}}var k=(o,s,e)=>{let d=o.activeTab==="queued",u=o.activeTab==="sent",a=(t,c)=>{let f=t.currentTarget,C=f.getBoundingClientRect(),x=f.querySelector(".comment-pin-badge")?.getBoundingClientRect();o.onThreadClick(c,{left:x?.left??C.left,top:C.top})};E(l`
    <style>${T}</style>
    <div class="comments-container" role="region" aria-label="Comments" jslog=${r.panel("comments").track({resize:!0})}>
      <div class="comments-toolbar" role="toolbar" jslog=${r.toolbar("comments-drawer")}>
        <div class="toolbar-left" role="tablist">
          <button
            class="tab-button ${d?"active":""}"
            role="tab"
            aria-selected=${d}
            @click=${()=>o.onTabSelect("queued")}
            jslog=${r.sectionHeader("queued").track({click:!0})}>
            ${i(n.queued)}
          </button>
          <button
            class="tab-button ${u?"active":""}"
            role="tab"
            aria-selected=${u}
            @click=${()=>o.onTabSelect("sent")}
            jslog=${r.sectionHeader("sent").track({click:!0})}>
            ${i(n.sent)}
          </button>
        </div>
        <button
          class="toolbar-button"
          title=${i(n.clearComments)}
          aria-label=${i(n.clearComments)}
          @click=${o.onClearAll}
          jslog=${r.action("clear-comments").track({click:!0})}>
          <devtools-icon name="clear"></devtools-icon>
        </button>
      </div>

      ${o.threads.length===0?l`
        <div class="comments-empty-state">
          <p>${i(d?n.noQueuedComments:n.noSentComments)}</p>
        </div>
      `:l`
        <ul class="comments-list" role="list">
          ${S(o.threads,t=>t.thread.id,t=>l`
              <li
                class="comment-thread-item ${t.thread.isOrphaned?"orphaned":""}"
                role="listitem"
                tabindex="0"
                @click=${c=>a(c,t.thread)}
                @keydown=${c=>{(c.key==="Enter"||c.key===" ")&&(c.preventDefault(),a(c,t.thread))}}
                jslog=${r.item("comment-thread").track({click:!0})}>
                <div class="comment-pin-badge" aria-hidden="true"></div>
                <span class="anchor-chip ${t.thread.isOrphaned?"orphaned":""}">
                  ${"node"in t.title?V(h.DOMLinkifier.DOMNodeLink,{node:t.title.node,options:{preventKeyboardFocus:!0,disabled:t.thread.isOrphaned}}):l`<span class="anchor-chip-text">${t.title.text}</span>`}
                  ${t.thread.isOrphaned?l`<span class="orphaned-label">(${i(n.removed)})</span>`:v.nothing}
                </span>
                <div class="comment-text">${t.commentText}</div>
                ${q(t.thread,o.onDeleteThread)}
              </li>
            `)}
        </ul>
      `}

      ${d?l`
        <div class="comments-footer">
          <devtools-icon
            class="info-icon"
            name="info"
            aria-label="Info"
            aria-details="comments-pane-info-tooltip"
            tabindex="0"
          ></devtools-icon>
          <devtools-tooltip
            id="comments-pane-info-tooltip"
            variant="rich"
          >
            <div class="info-tooltip-container">
              ${I(L.inputDisclaimer)}
            </div>
          </devtools-tooltip>
          <button
            class="send-agent-button"
            ?disabled=${o.threads.length===0}
            @click=${o.onSendToAgent}
            jslog=${r.action("comments-send-to-agent").track({click:!0})}>
            ${i(n.sendToAgent)}
          </button>
        </div>
      `:v.nothing}
    </div>
  `,e)},y=class extends b.Widget.Widget{static INJECT=[m.CommentManager.CommentManager];#s;#e;#t=new Map;#o="queued";constructor(s,[e]=[new m.CommentManager.CommentManager],d=k){super(s),this.#s=d,this.#e=e}#a=()=>{this.requestUpdate()};wasShown(){super.wasShown(),this.#e.addEventListener(m.CommentManager.Events.COMMENT_THREADS_CHANGED,this.#a,this),this.requestUpdate()}willHide(){this.#e.removeEventListener(m.CommentManager.Events.COMMENT_THREADS_CHANGED,this.#a,this),super.willHide()}#n=s=>{this.#o!==s&&(this.#o=s,this.requestUpdate())};#r=()=>{this.#t.clear(),this.#e.clear(),this.requestUpdate()};#i=(s,e)=>{w.Revealer.reveal(new m.CommentThread.RevealableThread(s,e))};#l=s=>{this.#t.delete(s),this.#e.removeCommentThread(s),this.requestUpdate()};#d=()=>{this.#e.sendQueuedThreads()};async performUpdate(s){let e;this.#o==="queued"?e=this.#e.getCommentThreads().filter(a=>a.status==="ACTIVE"):e=this.#e.getCommentThreads().filter(a=>a.status==="SENT_TO_AGENT"||a.status==="RESOLVED");let d=await Promise.all(e.map(async a=>{let t=this.#t.get(a.id);return t||(t=await D(a.anchor),this.#t.set(a.id,t)),{thread:a,title:t,commentText:a.comments[0]?.text??""}}));if(s?.aborted)return;let u={activeTab:this.#o,threads:d,onTabSelect:this.#n,onClearAll:this.#r,onThreadClick:this.#i,onDeleteThread:this.#l,onSendToAgent:this.#d};this.#s(u,void 0,this.contentElement)}};export{z as CommentsPane};
//# sourceMappingURL=comments.js.map
