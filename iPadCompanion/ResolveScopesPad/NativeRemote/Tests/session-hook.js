  globalThis.__sessionSelfTest=async()=>{
    globalThis.RM_TV_IP='127.0.0.1';
    const settings={iceServers:[],iceUseIpv4:true,iceUseIpv6:false,iceUseTcp:false,iceInterfaceAddresses:{udp4:'127.0.0.1'},codecs:{video:[new import_parameters.RTCRtpCodecParameters({mimeType:'video/H265',clockRate:90000,payloadType:96,rtcpFeedback:[{type:'nack'},{type:'nack',parameter:'pli'}]})]}};
    const a=new import_peer.RTCPeerConnection(settings),b=new import_peer.RTCPeerConnection(settings);
    const nativeExport=globalThis.__rmExportSRTP,exported=[];
    globalThis.__rmExportSRTP=(key,salt,profile)=>{nativeExport(key,salt,profile);exported.push({key:Buffer.from(key),salt:Buffer.from(salt),profile});};
    try{
      const tr=a.addTransceiver('video',{direction:'sendonly'}),dc=a.createDataChannel('control-test');
      let receiverChannel;
      const timeout=(name,ms=9000)=>new Promise((_,reject)=>setTimeout(()=>reject(Error(name+' timeout')),ms));
      const connected=new Promise(resolve=>{b.ondatachannel=e=>{receiverChannel=e.channel;e.channel.onmessage=m=>{if(m.data==='authenticated ping')resolve();};};dc.onopen=()=>dc.send('authenticated ping');});
      await a.setLocalDescription(await a.createOffer());await b.setRemoteDescription(a.localDescription);await b.setLocalDescription(await b.createAnswer());await a.setRemoteDescription(b.localDescription);
      await Promise.race([connected,timeout('ICE/DTLS/SCTP')]);
      if(exported.length!==2||exported.some(k=>k.profile!==1||k.key.length!==16||k.salt.length!==14))throw Error('SRTP native key callback shape');
      const dtlsA=a.dtlsTransports[0],dtlsB=b.dtlsTransports[0];
      const keysA=dtlsA.dtls.extractSessionKeys(16,14),keysB=dtlsB.dtls.extractSessionKeys(16,14);
      if(!keysA.localKey.equals(keysB.remoteKey)||!keysA.localSalt.equals(keysB.remoteSalt))throw Error('DTLS directional key mismatch');
      if(dtlsA.srtp||dtlsB.srtp)throw Error('JavaScript SRTP media session exists');
      // Opaque synthetic datagram checks byte-for-byte routing, not media decoding.
      const raw=Buffer.from([128,224,0,42,0,0,1,0,0,0,0,123,18,52,86,120,11,22,33,44,55,66,77,88]);
      const rawReceived=new Promise(resolve=>{globalThis.__rmTestRaw=bytes=>{if(!Buffer.from(bytes).equals(raw))throw Error('Native raw RTP modified');resolve();};});
      await dtlsA.iceTransport.connection.send(raw);await Promise.race([rawReceived,timeout('native RTP bypass',3000)]);
      const oldPC=pc,oldReceiver=videoReceiver,oldChannel=channel;pc=a;videoReceiver={dtlsTransport:dtlsA,rtcpSsrc:444,pliEnabled:true};channel=dc;
      try{
        const gotNACK=new Promise(resolve=>dtlsB.onRtcp.subscribe(p=>{if(p.type===205){if(p.feedback.mediaSourceSsrc!==123||p.feedback.lost.join(',')!=='3,5')throw Error('NACK contents');resolve();}}));
        await nack(123,[3,5]);await Promise.race([gotNACK,timeout('authenticated SRTCP NACK',3000)]);
        let sawIDR=false,sawPLI=false;
        const gotIDR=new Promise(resolve=>{receiverChannel.onmessage=m=>{const root=new FlatReader(m.data).root();if(root.scalar(0,'u8')!==4)throw Error('IDR request wire type');sawIDR=true;resolve();};});
        const gotPLI=new Promise(resolve=>dtlsB.onRtcp.subscribe(p=>{if(p.type===206&&p.feedback.mediaSsrc===123){sawPLI=true;resolve();}}));
        lastIDR=0;idr();try{await Promise.race([Promise.all([gotIDR,gotPLI]),timeout('authenticated SCTP IDR + SRTCP PLI',3000)]);}catch(e){throw Error(String(e)+' sawIDR='+sawIDR+' sawPLI='+sawPLI+' pliEnabled='+videoReceiver.pliEnabled+' stats='+JSON.stringify(stats));}
      }finally{pc=oldPC;videoReceiver=oldReceiver;channel=oldChannel;}
      return 'HEVC SDP; fingerprint-verified ICE/DTLS; authenticated SCTP; directional SRTP key export; raw RTP native bypass; authenticated SRTCP NACK; sender stream IDR type4';
    }finally{globalThis.__rmExportSRTP=nativeExport;exported.length=0;delete globalThis.__rmTestRaw;await a.close();await b.close();}
  };
