#!/usr/bin/env python3
"""Real HTTP OAuth + MCP test. Only isolated synthetic stores; no provider accounts or API keys."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.parse
import uuid


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('local_binary', type=Path)
    parser.add_argument('http_binary', type=Path)
    args = parser.parse_args()
    local, server = args.local_binary.resolve(), args.http_binary.resolve()
    with tempfile.TemporaryDirectory(prefix='vauldy-oauth-wire-') as temp:
        root = Path(temp).resolve(); installation = root/'installation'
        with socket.socket() as pick:
            pick.bind(('127.0.0.1', 0)); port = pick.getsockname()[1]
        origin = 'https://vauldy.example.test'; resource = origin+'/mcp'
        vault = root/'documents.json'
        documents = [dict(id=str(uuid.uuid4()),title=f'Synthetische Wartung {i}',sourceName=f'test-{i}.pdf',status='indexed',pageCount=1,
                          ocrText=f'--- Seite 1 ---\nWartung Nummer {i}, Betrag 49,99 EUR.\nE-Mail: private-{i}@example.com') for i in range(55)]
        vault.write_text(json.dumps(documents))
        before_vault = vault.read_bytes()
        profiles = {}
        for provider, docs in [('chatgpt',documents[:53]),('claude',documents[53:])]:
            connection, revision = str(uuid.uuid4()), str(uuid.uuid4())
            path = installation/'connections'/connection/'profile.json'; path.parent.mkdir(parents=True,mode=0o700)
            profile = dict(version=1,revision=revision,connectionID=connection,connectionName=provider,enabled=True,
                           vaultPath=str(vault),allowedDocumentIDs=[d['id'] for d in docs],acknowledgedCloudDisclosure=True)
            path.write_text(json.dumps(profile)); path.chmod(0o600)
            profiles[provider] = (path,profile,path.read_bytes())
        def command(*values):
            result = subprocess.run([str(local),*map(str,values)],capture_output=True,text=True,timeout=30)
            assert result.returncode==0, f'Local OAuth operation failed: {result.stderr}'
            return json.loads(result.stdout) if result.stdout.strip() else None
        def request(method,path,body=None,headers=None):
            connection = http.client.HTTPConnection('127.0.0.1',port,timeout=35)
            try:
                connection.request(method,path,body=body,headers=headers or {})
                response = connection.getresponse()
                data=response.read(); status=response.status; returned={k.lower():v for k,v in response.getheaders()}
                try: value=json.loads(data)
                except (ValueError,UnicodeDecodeError): value=data.decode('utf-8',errors='replace')
                return status,returned,value
            finally:connection.close()
        def post(path,fields):
            return request('POST',path,urllib.parse.urlencode(fields),{'Content-Type':'application/x-www-form-urlencoded'})
        command('oauth-configure','--root',installation,'--origin',origin,'--port',port)
        process = subprocess.Popen([str(server),'--root',str(installation)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        try:
            deadline=time.monotonic()+15
            while True:
                try:
                    status,_,metadata=request('GET','/.well-known/oauth-protected-resource')
                    if status==200:break
                except OSError:pass
                assert process.poll() is None,'HTTP service stopped before readiness'
                assert time.monotonic()<deadline,'HTTP service did not become ready'
                time.sleep(.1)
            assert metadata['resource']==resource
            assert request('POST','/mcp','{}',{'Content-Type':'application/json'})[0]==401
            assert 'resource_metadata=' in request('GET','/mcp')[1]['www-authenticate']
            oauth=request('GET','/.well-known/oauth-authorization-server')[2]
            assert oauth['code_challenge_methods_supported']==['S256'] and oauth['token_endpoint_auth_methods_supported']==['none']
            assert oauth['authorization_response_iss_parameter_supported']
            assert request('POST','/oauth/approve','{}',{'Content-Type':'application/json'})[0]==404
            for redirect in ['http://claude.ai/callback','https://attacker.example/callback','https://claude.ai.attacker.example/callback']:
                status,_,_=request('POST','/oauth/register',json.dumps(dict(redirect_uris=[redirect])),{'Content-Type':'application/json'})
                assert status==401
            assert post('/oauth/token',{'grant_type':'client_credentials'})[0]==400
            flows={}
            def connect(provider,deny=False):
                redirect='https://chatgpt.com/connector_platform_oauth_redirect' if provider=='chatgpt' else 'https://claude.ai/api/mcp/auth_callback'
                status,_,client=request('POST','/oauth/register',json.dumps(dict(redirect_uris=[redirect],client_name='Untrusted claimed label',token_endpoint_auth_method='none',grant_types=['authorization_code','refresh_token'],response_types=['code'])),{'Content-Type':'application/json'})
                assert status==201
                verifier=secrets.token_urlsafe(32)
                challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
                fields=dict(response_type='code',client_id=client['client_id'],redirect_uri=redirect,resource=resource,
                            scope='documents:read',state=secrets.token_urlsafe(16),code_challenge=challenge,code_challenge_method='S256')
                status,headers,_=request('GET','/oauth/authorize?'+urllib.parse.urlencode(fields))
                assert status==303 and headers['location']==origin+'/oauth/continue'
                cookie=headers['set-cookie'].split(';')[0]
                assert all(value in headers['set-cookie'] for value in ['Secure','HttpOnly','SameSite=Lax'])
                status,_,html=request('GET','/oauth/continue',headers={'Cookie':cookie})
                assert status==200 and 'API' not in html
                pending=command('oauth-pending','--root',installation)
                assert len(pending)==1 and pending[0]['provider']==provider and pending[0]['confirmation'] in html
                if deny:
                    command('oauth-deny','--root',installation,'--request',pending[0]['id'])
                else:
                    profile=profiles[provider][1]
                    command('oauth-approve','--root',installation,'--request',pending[0]['id'],'--profile',profile['connectionID'],'--revision',profile['revision'])
                status,headers,_=request('GET','/oauth/continue',headers={'Cookie':cookie})
                assert status==303
                result=urllib.parse.parse_qs(urllib.parse.urlsplit(headers['location']).query)
                assert result['state']==[fields['state']] and result['iss']==[origin]
                if deny:
                    assert result['error']==['access_denied'] and 'code' not in result; return None
                token_fields=dict(grant_type='authorization_code',client_id=client['client_id'],redirect_uri=redirect,resource=resource,code=result['code'][0],code_verifier=verifier)
                assert post('/oauth/token',dict(token_fields,code_verifier='z'*43))[0]==400
                assert post('/oauth/token',dict(token_fields,resource='https://foreign.example/mcp'))[0]==400
                status,_,tokens=post('/oauth/token',token_fields)
                assert status==200 and tokens['token_type']=='Bearer' and tokens['scope']=='documents:read'
                stored=(installation/'oauth/credentials.json').read_text()
                assert all(secret not in stored for secret in [tokens['access_token'],tokens['refresh_token'],token_fields['code']])
                return dict(tokens=tokens,client=client['client_id'])
            def rpc(flow,method,params=None,notify=False):
                headers={'Authorization':'Bearer '+flow['tokens']['access_token'],'Content-Type':'application/json','Accept':'application/json, text/event-stream','MCP-Protocol-Version':'2025-06-18'}
                if flow.get('session'):headers['Mcp-Session-Id']=flow['session']
                body=dict(jsonrpc='2.0',method=method,params=params or {})
                if not notify:body['id']=str(uuid.uuid4())
                status,returned,value=request('POST','/mcp',json.dumps(body),headers)
                if method=='initialize' and status==200:flow['session']=returned['mcp-session-id']
                return status,value
            for provider in ['chatgpt','claude']:
                flows[provider]=connect(provider)
                status,initialized=rpc(flows[provider],'initialize',dict(protocolVersion='2025-06-18',clientInfo=dict(name='Synthetic OAuth client',version='1'),capabilities=dict(experimental={'nested':{'ok':True}})))
                assert status==200 and initialized['result']['serverInfo']['version']=='0.12.0',(status,initialized)
                assert rpc(flows[provider],'notifications/initialized',notify=True)[0]==202
                status,tools=rpc(flows[provider],'tools/list')
                assert status==200 and len(tools['result']['tools'])==4
                assert all(t['securitySchemes']==[dict(type='oauth2',scopes=['documents:read'])] and t['_meta']['securitySchemes']==t['securitySchemes'] for t in tools['result']['tools'])
            chat=flows['chatgpt'];claude=flows['claude']
            items=[];cursor=None;pages=0
            while True:
                status,result=rpc(chat,'tools/call',dict(name='list_documents',arguments=dict(cursor=cursor) if cursor else dict(pageSize=25)))
                assert status==200 and not result['result'].get('isError'),(status,result)
                value=result['result']['structuredContent'];pages+=1;items+=value['items'];cursor=value.get('nextCursor')
                assert value['totalCount']==53
                if not cursor:
                    assert value['retrievalComplete'];break
            assert pages==3 and len(items)==53 and len({i['document'] for i in items})==53
            status,result=rpc(chat,'tools/call',dict(name='read_document',arguments=dict(document=items[0]['document'])))
            assert status==200 and '49,99 EUR' in json.dumps(result) and '@example.com' not in json.dumps(result)
            assert str(root) not in json.dumps(result) and all(d['id'] not in json.dumps(result) for d in documents)
            headers={'Authorization':'Bearer '+claude['tokens']['access_token'],'Content-Type':'application/json','Accept':'application/json','Mcp-Session-Id':chat['session']}
            assert request('POST','/mcp',json.dumps(dict(jsonrpc='2.0',id=99,method='tools/list')),headers)[0]==404
            assert request('POST','/mcp','{}',dict(headers,Origin='https://attacker.example'))[0]==403
            status,result=rpc(claude,'tools/call',dict(name='list_documents',arguments={}))
            assert status==200 and result['result']['structuredContent']['totalCount']==2
            original=chat['tokens']
            status,_,replacement=post('/oauth/token',dict(grant_type='refresh_token',client_id=chat['client'],refresh_token=original['refresh_token'],resource=resource))
            assert status==200
            assert rpc(chat,'tools/list')[0]==401
            chat['tokens']=replacement
            assert rpc(chat,'tools/call',dict(name='read_document',arguments=dict(document=items[0]['document'])))[0]==200
            assert post('/oauth/token',dict(grant_type='refresh_token',client_id=chat['client'],refresh_token=original['refresh_token'],resource=resource))[0]==400
            assert rpc(chat,'tools/list')[0]==401
            assert rpc(claude,'tools/list')[0]==200
            connect('chatgpt',deny=True)
            status,_,_=post('/oauth/revoke',dict(token=claude['tokens']['refresh_token'],client_id=claude['client']))
            assert status==200 and rpc(claude,'tools/list')[0]==401
            # OAuth credentials survive service restart; old HTTP sessions correctly require initialization.
            restarted=connect('claude')
            command('oauth-stop','--root',installation)
            process.wait(timeout=5)
            command('oauth-start','--root',installation)
            assert command('oauth-status','--root',installation)['running']
            status,initialized=rpc(restarted,'initialize',dict(protocolVersion='2025-06-18',clientInfo=dict(name='Synthetic reconnected client',version='1'),capabilities={}))
            assert status==200
            assert rpc(restarted,'notifications/initialized',notify=True)[0]==202
            assert rpc(restarted,'tools/list')[0]==200
            assert vault.read_bytes()==before_vault
            assert all(path.read_bytes()==before for path,_,before in profiles.values())
            for file in (installation/'oauth').iterdir():
                if file.is_file():assert file.stat().st_mode & 0o077==0
            print('PASS: keyless ChatGPT/Claude OAuth, local consent/denial, PKCE, issuer/resource/redirect binding, real HTTP MCP discovery, 53-document pagination, sanitized reads, cross-provider isolation, refresh rotation/reuse, immediate revocation, private hashed credentials, unchanged synthetic vault/profiles.')
        finally:
            command('oauth-stop','--root',installation)
            stop_deadline=time.monotonic()+5
            while command('oauth-status','--root',installation)['running'] and time.monotonic()<stop_deadline:time.sleep(.1)
            assert not command('oauth-status','--root',installation)['running']
            try:process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate();process.wait(timeout=5)
            stderr=process.stderr.read().decode()
            assert not any(d['id'] in stderr or '@example.com' in stderr for d in documents)


if __name__=='__main__':main()
