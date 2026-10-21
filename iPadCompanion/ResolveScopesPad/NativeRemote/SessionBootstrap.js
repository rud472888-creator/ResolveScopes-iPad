// Host shims for the control-only werift session. No browser/UI thread.
globalThis.self=globalThis;
globalThis.window=globalThis;
globalThis.navigator={userAgent:'ResolveScopes iPad JavaScriptCore'};
globalThis.location={protocol:'file:',hostname:'localhost'};
globalThis.DOMException=class DOMException extends Error {constructor(message='',name='Error'){super(message);this.name=name;}};
globalThis.Event=class Event {constructor(type,options={}){this.type=String(type);Object.assign(this,options);}preventDefault(){this.defaultPrevented=true;}stopPropagation(){}};
globalThis.AbortSignal=class AbortSignal {
 constructor(){this.aborted=false;this.reason=undefined;this.onabort=null;this.__listeners=[];}
 addEventListener(type,callback,options={}){
  if(type!=='abort'||callback==null)return;
  const capture=typeof options==='boolean'?options:!!options?.capture;
  if(this.__listeners.some(x=>x.callback===callback&&x.capture===capture))return;
  this.__listeners.push({callback,capture,once:typeof options==='object'&&!!options?.once});
 }
 removeEventListener(type,callback,options={}){
  if(type!=='abort')return;const capture=typeof options==='boolean'?options:!!options?.capture;
  this.__listeners=this.__listeners.filter(x=>x.callback!==callback||x.capture!==capture);
 }
 dispatchEvent(event){
  if(event.type!=='abort')return true;event.target=this;event.currentTarget=this;
  const listeners=this.__listeners.slice();
  for(const item of listeners){
   if(!this.__listeners.includes(item))continue;
   if(item.once)this.removeEventListener('abort',item.callback,item.capture);
   try{if(typeof item.callback==='function')item.callback.call(this,event);else item.callback.handleEvent?.(event);}catch(error){console.error('Abort listener error',error);}
  }
  if(typeof this.onabort==='function'){try{this.onabort.call(this,event);}catch(error){console.error('Abort listener error',error);}}
  return !event.defaultPrevented;
 }
 throwIfAborted(){if(this.aborted)throw this.reason;}
 __abort(reason){if(this.aborted)return;this.aborted=true;this.reason=reason===undefined?new DOMException('The operation was aborted.','AbortError'):reason;this.dispatchEvent(new Event('abort'));}
 static abort(reason){const signal=new AbortSignal();signal.__abort(reason);return signal;}
 static timeout(milliseconds){if(!Number.isInteger(milliseconds)||milliseconds<0)throw new RangeError('Invalid timeout');const signal=new AbortSignal();setTimeout(()=>signal.__abort(new DOMException('The operation timed out.','TimeoutError')),milliseconds);return signal;}
 static any(signals){const signal=new AbortSignal(),subscriptions=[];const stop=reason=>{if(signal.aborted)return;for(const [s,fn]of subscriptions)s.removeEventListener('abort',fn);subscriptions.length=0;signal.__abort(reason);};for(const s of signals){if(!(s instanceof AbortSignal))throw new TypeError('Expected AbortSignal');if(s.aborted){stop(s.reason);break;}const fn=()=>stop(s.reason);subscriptions.push([s,fn]);s.addEventListener('abort',fn,{once:true});}return signal;}
};
globalThis.AbortController=class AbortController {constructor(){this.signal=new AbortSignal();}abort(reason){this.signal.__abort(reason);}};
globalThis.performance={now:()=>__rmNow()};
globalThis.console={log:(...a)=>__rmLog(a.map(String).join(' ')),warn:(...a)=>__rmLog(a.map(String).join(' ')),error:(...a)=>__rmLog(a.map(String).join(' '))};
globalThis.setTimeout=(fn,ms=0,...a)=>__rmTimer(()=>fn(...a),Math.max(0,Number(ms)||0),false);
globalThis.setInterval=(fn,ms=0,...a)=>__rmTimer(()=>fn(...a),Math.max(1,Number(ms)||1),true);
globalThis.clearTimeout=globalThis.clearInterval=id=>__rmCancelTimer(Number(id));
globalThis.queueMicrotask=fn=>Promise.resolve().then(fn);
globalThis.TextEncoder=class {encode(s=''){return __rmUTF8(String(s));}};
globalThis.TextDecoder=class {constructor(label='utf-8',options={}){if(!/^utf-?8$/i.test(label))throw Error('Only UTF-8 is supported');this.fatal=!!options.fatal;}decode(bytes=new Uint8Array()){const s=__rmDecodeUTF8(bytes,this.fatal);if(s===null)throw Error('Invalid UTF-8');return s;}};
globalThis.atob=s=>__rmBase64Decode(String(s));
globalThis.btoa=s=>__rmBase64Encode(String(s));
globalThis.URL=class {
 constructor(s){const v=__rmURL(String(s));if(!v)throw Error('Invalid URL');Object.assign(this,v);}
 get href(){return this.protocol+'//'+(this.username?encodeURIComponent(this.username)+(this.password?':'+encodeURIComponent(this.password):'')+'@':'')+this.hostname+(this.port?':'+this.port:'')+(this.pathname||'/')+(this.search||'')+(this.hash||'');}
 toString(){return this.href;}
};
globalThis.URLSearchParams=class {constructor(s=''){this.values=new Map(String(s).replace(/^\?/,'').split('&').filter(Boolean).map(x=>{const at=x.indexOf('=');return at<0?[decodeURIComponent(x),'']:[decodeURIComponent(x.slice(0,at)),decodeURIComponent(x.slice(at+1))];}));}get(k){return this.values.get(k)??null;}};
const algorithmName=a=>typeof a==='string'?a:a?.name;
const keyObject=(id,type,algorithm)=>({__id:id,type,algorithm,extractable:true,usages:type==='private'?['sign']:['verify']});
globalThis.crypto={
 getRandomValues(array){array.set(__rmRandom(array.byteLength));return array;},
 randomUUID(){const b=this.getRandomValues(new Uint8Array(16));b[6]=(b[6]&15)|64;b[8]=(b[8]&63)|128;const h=Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');return h.slice(0,8)+'-'+h.slice(8,12)+'-'+h.slice(12,16)+'-'+h.slice(16,20)+'-'+h.slice(20);},
 subtle:{
  async digest(algorithm,data){return __rmHash(algorithmName(algorithm),data).buffer;},
  async generateKey(algorithm,extractable,usages){if(algorithmName(algorithm)!=='ECDSA'||algorithm.namedCurve!=='P-256')throw Error('Unsupported WebCrypto key algorithm');const id=__rmGenerateKey();return {privateKey:keyObject(id,'private',algorithm),publicKey:keyObject(id,'public',algorithm)};},
  async exportKey(format,key){const b=__rmExportKey(format,key.__id,key.type);if(!b)throw Error('Unsupported key export');return b.buffer;},
  async importKey(format,data,algorithm,extractable,usages){if(algorithmName(algorithm)!=='ECDSA'||algorithm.namedCurve!=='P-256')throw Error('Unsupported key import');const type=usages.includes('sign')?'private':'public';const id=__rmImportKey(format,data,type);if(!id)throw Error('Invalid key');return keyObject(id,type,algorithm);},
  async sign(algorithm,key,data){if(algorithmName(algorithm)!=='ECDSA'||algorithmName(algorithm.hash)!=='SHA-256')throw Error('Unsupported signing algorithm');const b=__rmSign(key.__id,data);if(!b)throw Error('Signing failed');return b.buffer;},
  async verify(algorithm,key,signature,data){if(algorithmName(algorithm)!=='ECDSA'||algorithmName(algorithm.hash)!=='SHA-256')throw Error('Unsupported verification algorithm');return __rmVerify(key.__id,signature,data);}
 }
};
// Same SRTP AES-128-CTR / HMAC algorithms, accelerated by platform crypto.
// Unsupported algorithms retain the existing implementation; no tag bypass.
globalThis.__rmNativeCipher=(name,key,iv)=>{
 if(String(name).toLowerCase()!=='aes-128-ctr')return null;
 const k=Buffer.from(key),counter=Buffer.from(iv);let offset=0,ended=false;
 return {update(input,inputEncoding,outputEncoding){if(ended)throw Error('Cipher is finalized');const data=typeof input==='string'?Buffer.from(input,inputEncoding):Buffer.from(input);const bytes=__rmAESCTR(k,counter,data,offset);if(!bytes)throw Error('Native AES-CTR failed');offset+=data.length;const result=Buffer.from(bytes);return outputEncoding?result.toString(outputEncoding):result;},final(encoding){ended=true;return encoding?'':Buffer.alloc(0);},setAutoPadding(){return this;}};
};
globalThis.__rmNativeHMAC=(name,key)=>{
 if(!['sha1','sha256','sha384','sha512'].includes(String(name).toLowerCase().replace(/-/g,'')))return null;
 const k=Buffer.from(key),chunks=[];let done=false;
 return {update(input,encoding){if(done)throw Error('Digest is finalized');chunks.push(typeof input==='string'?Buffer.from(input,encoding):Buffer.from(input));return this;},digest(encoding){if(done)throw Error('Digest is finalized');done=true;const bytes=__rmHMAC(String(name),k,Buffer.concat(chunks));chunks.length=0;if(!bytes)throw Error('Native HMAC failed');const result=Buffer.from(bytes);return encoding?result.toString(encoding):result;}};
};
const sockets=new Map();
globalThis.__rmUDPRegister=(fd,socket)=>sockets.set(fd,socket);
globalThis.__rmUDPUnregister=fd=>sockets.delete(fd);
globalThis.__rmUDPDeliver=(fd,bytes,host,port,receivedMS=performance.now(),kernelAgeMS=-1)=>{const s=sockets.get(fd);if(!s||s.closed)return;globalThis.__rmCurrentPacketReceiveMS=receivedMS;globalThis.__rmCurrentPacketKernelAgeMS=kernelAgeMS;RM_SOCKET_STATS.rxPackets++;RM_SOCKET_STATS.rxBytes+=bytes.length;if((bytes[0]&192)===128)RM_SOCKET_STATS.rtpLikePackets++;s.emit('message',Buffer.from(bytes),{address:host,port,family:'IPv4',size:bytes.length});};
const webSockets=new Map();let nextWebSocket=1;
globalThis.WebSocket=class {
 static CONNECTING=0;static OPEN=1;static CLOSING=2;static CLOSED=3;
 constructor(url){this.__id=nextWebSocket++;this.readyState=0;this.binaryType='arraybuffer';webSockets.set(this.__id,this);__rmWSOpen(this.__id,String(url));}
 send(data){if(this.readyState!==1)throw Error('WebSocket is not open');__rmWSSend(this.__id,data);}
 close(){if(this.readyState>=2)return;this.readyState=2;__rmWSClose(this.__id);}
};
globalThis.__rmWSEvent=(id,type,data)=>{const ws=webSockets.get(id);if(!ws)return;if(type==='open'){ws.readyState=1;ws.onopen?.({target:ws});}else if(type==='data'){ws.onmessage?.({data:data.buffer.slice(data.byteOffset,data.byteOffset+data.byteLength)});}else if(type==='error'){ws.onerror?.({message:String(data),target:ws});}else if(type==='close'){ws.readyState=3;ws.onclose?.({target:ws});webSockets.delete(id);}};
// No media parsing, decryption, reordering, frame assembly or timers here.
globalThis.postMessage=message=>__rmPost(message);
globalThis.__rmSendCommand=command=>globalThis.onmessage?.({data:command});
