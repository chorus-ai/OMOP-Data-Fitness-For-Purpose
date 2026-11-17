"""One-site PostgreSQL runner for source-preserving Data Expectations checks."""
from pathlib import Path
import csv, hashlib, json, time
from datetime import datetime, timezone
from . import pipeline
from .single_site import assert_private_paths, validate_site_alias, export_site

from .paths import ROOT, CONFIG, resolve_query_path

def entries():
    result=json.loads((CONFIG/'screening_manifest.json').read_text(encoding='utf-8'))
    # No complete final transfusion query was recovered: retain reviewed aggregate
    # adaptations explicitly, never the original patient-row exploratory scripts.
    for e in json.loads((CONFIG/'manifest.json').read_text(encoding='utf-8')):
        if e['topic']=='transfusion':
            e=dict(e,status='adapted-not-exact-replay',source_url='',adaptation='v0.2 aggregate reconstruction; final consolidated historical query unavailable.')
            result.append(e)
    for e in result:
        sql=resolve_query_path(CONFIG / ('manifest.json' if e['topic'] == 'transfusion' else 'screening_manifest.json'), e['path']).read_text(encoding='utf-8')
        digest=hashlib.sha256(sql.encode()).hexdigest()
        if e.get('sha256') and digest!=e['sha256']:
            raise ValueError('Query checksum mismatch: '+e['id'])
        pipeline.validate_sql(sql.replace('{{schema}}','omopcdm'))
        e['_sql']=sql;e['sha256']=digest
    return result

def normalize(raw, entry, site):
    row=pipeline.marker_row(entry,site,'observed','')
    row.update(category=str(raw.get('drug_name') or raw.get('category') or raw.get('section') or entry['topic']),
               variable=str(raw['variable']),section=str(raw.get('section') or ''),
               note=entry['adaptation'])
    row.update(pipeline.parse_result(raw['result'],variable=row['variable']))
    row['numerator']=raw.get('numerator');row['denominator']=raw.get('denominator')
    if raw.get('denominator') is not None and float(raw['denominator']) == 0 and raw['result'] is None:
        row.update(status='denominator_zero', result='N/A (zero denominator)')
    return row

def run_screening(*,host,port,dbname,user,password,schema,site,output_dir,
                  confirm_site_connection=False,timeout=300,include_pdf=True,connect=None):
    """Connect using explicit fields; never persist password, host or username."""
    validate_site_alias(site);quoted=pipeline.schema_name(schema)
    assert_private_paths(output_dir,mode='database')
    output=Path(output_dir).resolve()
    if output.exists() and any(output.iterdir()): raise ValueError('Choose a new output directory.')
    if confirm_site_connection is not True: raise ValueError('Confirm one-site connection and schema before execution.')
    if not all(isinstance(v,str) and v.strip() for v in [host,dbname,user]): raise ValueError('Host, database and user are required.')
    if isinstance(port,bool) or not 1<=int(port)<=65535: raise ValueError('Invalid port.')
    if isinstance(timeout,bool) or not isinstance(timeout,int) or timeout<1: raise ValueError('Timeout must be positive.')
    pack=entries()
    if connect is None:
        import psycopg
        connect=psycopg.connect
    try:
        conn=connect(host=host,port=int(port),dbname=dbname,user=user,password=password,
                     connect_timeout=10,application_name='data_expectations_readonly')
    except Exception:
        raise RuntimeError('Connection failed; check host/database/user and local authentication. Details hidden to protect credentials.') from None
    rows=[];executions=[];raw_outputs=[]
    try:
        conn.read_only=True
        for e in pack:
            begin=time.monotonic()
            try:
                with conn.transaction():
                    with conn.cursor() as cur:
                        cur.execute("SELECT set_config('statement_timeout', %s, true)",(str(timeout*1000),))
                        cur.execute("SELECT set_config('lock_timeout', '5000', true)")
                        cur.execute('SELECT table_name FROM information_schema.tables WHERE table_schema=%s',(schema,))
                        missing=set(e['required_tables'])-{v[0] for v in cur.fetchall()}
                        if missing:
                            rows.append(pipeline.marker_row(e,site,'not_available','Missing table or permission: '+', '.join(sorted(missing))))
                            executions.append(dict(id=e['id'],status='not_available',sha256=e['sha256']))
                            continue
                        cur.execute(e['_sql'].replace('{{schema}}',quoted))
                        cols=[c.name for c in cur.description]
                        if not {'variable','result'}<=set(cols) or set(cols)-{'category','section','drug_name','variable','result','numerator','denominator'}:
                            raise ValueError('Unexpected aggregate result columns')
                        data=cur.fetchmany(10001)
                        if len(data)>10000: raise ValueError('Aggregate row limit exceeded')
                        raw=[dict(zip(cols,r)) for r in data]
                        rows.extend(normalize(r,e,site) for r in raw)
                        if not raw: rows.append(pipeline.marker_row(e,site,'not_assessed','No rows returned; not a zero result.'))
                        raw_outputs.append((e['id'],cols,data))
                        executions.append(dict(id=e['id'],status='completed',sha256=e['sha256'],result_rows=len(data),seconds=round(time.monotonic()-begin,3)))
            except Exception as exc:
                rows.append(pipeline.marker_row(e,site,'error','Query failed; inspect local query and schema. No result inferred.'))
                executions.append(dict(id=e['id'],status='error',sha256=e['sha256'],error_type=type(exc).__name__,sqlstate=getattr(exc,'sqlstate',None)))
    finally:
        conn.close()
        password=None
    metadata=dict(mode='database',site=site,schema=schema,cdm_version='5.4 target; actual release must be confirmed',
        vocabulary_version='not supplied',executions=executions,source_revision='Data Expectations historical query pack v0.3; interpretation release v0.4',
        scope='All data visible in the selected single-site schema; no cohort/date restriction. Six source-preserving queries plus explicitly adapted transfusion aggregates.',
        privacy='Local unsuppressed aggregate output; disclosure review required before sharing.')
    result=export_site(rows,metadata,site,output,include_pdf=include_pdf)
    raw_dir=output/'raw_queries';raw_dir.mkdir()
    for query,cols,data in raw_outputs:
        # Match source columns and values; guard CSV formula execution.
        safe=[{k:pipeline.safe_csv_value(v) if hasattr(pipeline,'safe_csv_value') else v for k,v in zip(cols,r)} for r in data]
        pipeline.write_csv(raw_dir/(query+'.csv'),safe,cols)
    audit=[{k:v for k,v in e.items() if k!='_sql'} for e in pack]
    (output/'query_provenance.json').write_text(json.dumps(audit,indent=2),encoding='utf-8')
    result['executions']=executions
    result['status']='completed' if all(x['status']=='completed' for x in executions) else 'partial'
    return result

def notebook_ui():
    """Display settings and one explicit run button. Password prompted at run time."""
    import ipywidgets as w
    from IPython.display import display, clear_output
    from getpass import getpass
    fields={k:w.Text(value=v,description=k) for k,v in dict(host='localhost',dbname='',user='',schema='omopcdm',site='Site_01').items()}
    port=w.IntText(value=5432,description='port')
    timeout=w.IntText(value=300,description='timeout (s)')
    parent=w.Text(value=str(ROOT.parent/'private_results'),description='output root')
    attest=w.Checkbox(description='This database/schema contains only the selected site',value=False,indent=False)
    button=w.Button(description='Run all screening checks',button_style='primary',layout=w.Layout(width='250px'))
    status=w.Output()
    def click(_):
        button.disabled=True
        with status:
            clear_output()
            secret=None
            try:
                if not attest.value: raise ValueError('Confirm the single-site scope first.')
                secret=getpass('Database password (memory only; not saved): ')
                stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
                result=run_screening(**{k:v.value for k,v in fields.items()},port=port.value,password=secret,
                    timeout=timeout.value,output_dir=Path(parent.value)/(fields['site'].value+'_'+stamp),confirm_site_connection=True)
                print('Run status:',result['status'])
                for x in result['executions']: print(x['id'],':',x['status'])
                print('Local report and complete results:',result['output_dir'])
            except Exception as exc:
                print('Assessment stopped:',str(exc) if isinstance(exc,(ValueError,RuntimeError)) else type(exc).__name__)
            finally:
                secret=None;button.disabled=False
    button.on_click(click)
    display(w.VBox(list(fields.values())+[port,timeout,parent,attest,button,status]))
    return button
