/** Dedicated release-only R2 binding. Objects stay unavailable until their approved hash metadata matches. */
export async function releaseBucketResponse(request, env = {}) {
 const pathname=new URL(request.url).pathname;
 let retained = {};
 // Explicit archive names and hashes only. Invalid configuration fails closed.
 if (env.AIM_RELEASE_MAC_ARCHIVES !== undefined) {
  try {
   const parsed = JSON.parse(env.AIM_RELEASE_MAC_ARCHIVES);
   if (!parsed || Array.isArray(parsed) || typeof parsed !== 'object' || Object.entries(parsed).some(([name, hash]) => !/^[A-Za-z0-9._-]+\.dmg$/.test(name) || typeof hash !== 'string' || !/^[a-f0-9]{64}$/.test(hash))) throw Error('invalid archive allowlist');
   retained = parsed;
  } catch { return new Response(null, {status:503,headers:{'Cache-Control':'no-store','X-Content-Type-Options':'nosniff'}}); }
 }
 const current = env.AIM_RELEASE_MAC_FILENAME;
 const currentHash = env.AIM_RELEASE_MAC_SHA256;
 if (/^[A-Za-z0-9._-]+\.dmg$/.test(current ?? '') && /^[a-f0-9]{64}$/.test(currentHash ?? '')) {
  if (Object.hasOwn(retained,current) && retained[current] !== currentHash) return new Response(null,{status:503,headers:{'Cache-Control':'no-store'}});
  retained = {...retained,[current]:currentHash};
 }
 const match = /^\/(updates|downloads)\/([A-Za-z0-9._-]+\.dmg)$/.exec(pathname);
 const filename = match?.[2];
 const mac = Boolean(filename && Object.hasOwn(retained, filename));
 const feed=pathname==='/updates/appcast.xml';
 const expected=feed?env.AIM_RELEASE_FEED_SHA256:mac?retained[filename]:undefined;
 if(!env.AIM_RELEASE_BUCKET) return null;
 const headers=new Headers({'X-Content-Type-Options':'nosniff','Cache-Control':'no-store'});
 const fail=(status)=>new Response(null,{status,headers});
 if(!feed&&!mac || !/^[a-f0-9]{64}$/.test(expected ?? '')) return fail(404);
 const key=feed?'updates/appcast.xml':`updates/${filename}`;
 try {
  // Head first: validate exact key/hash before any body delivery and resolve bounded byte ranges.
  const head=await env.AIM_RELEASE_BUCKET.head(key);
  if(!head || head.customMetadata?.sha256!==expected) return fail(404);
  const type=head.httpMetadata?.contentType;
  if(feed?!['application/xml','text/xml','application/rss+xml'].includes(type):!['application/octet-stream','application/x-apple-diskimage','application/x-dmg'].includes(type)) return fail(404);
  let range;
  if(request.method==='GET' && request.headers.has('Range') && (!request.headers.has('If-Range') || request.headers.get('If-Range')===(head.httpEtag ?? `"${head.etag}"`))) {
   const match=/^bytes=(\d*)-(\d*)$/.exec(request.headers.get('Range'));
   if(!match || (!match[1]&&!match[2])) {headers.set('Content-Range',`bytes */${head.size}`);return fail(416);}
   const start=match[1]?Number(match[1]):Math.max(0,head.size-Number(match[2]));
   const end=match[1]&&match[2]?Math.min(head.size-1,Number(match[2])):head.size-1;
   if(![start,end].every(Number.isSafeInteger)||start<0||start>=head.size||end<start){headers.set('Content-Range',`bytes */${head.size}`);return fail(416);}
   range={offset:start,length:end-start+1};
  }
  const object=request.method==='HEAD'?head:await env.AIM_RELEASE_BUCKET.get(key,range?{range}:undefined);
  if(!object || object.customMetadata?.sha256!==expected || object.etag!==head.etag) return fail(503);
  headers.set('Content-Type',type);
  headers.set('Accept-Ranges','bytes');
  headers.set('ETag',object.httpEtag ?? `"${object.etag}"`);
  headers.set('Cache-Control',feed?'public, max-age=60, must-revalidate':'public, max-age=86400');
  headers.set('Content-Length',String(range?range.length:head.size));
  if(mac) headers.set('Content-Disposition',`attachment; filename="${filename}"`);
  if(range) headers.set('Content-Range',`bytes ${range.offset}-${range.offset+range.length-1}/${head.size}`);
  return new Response(request.method==='HEAD'?null:object.body,{status:range?206:200,headers});
 } catch {return fail(503);}
}
