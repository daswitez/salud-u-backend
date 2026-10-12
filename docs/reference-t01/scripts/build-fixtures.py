import json
from pathlib import Path
out=Path(__file__).resolve().parent.parent
ids={k:f'00000000-0000-4000-8000-{i:012d}' for i,k in enumerate(['profile','patient','staff','career','specialty','request','slot','appointment','encounter','document','background','referral','export'],1)}
t='2026-10-11T12:00:00.000Z'; cases=[]
def db(name,data=None,error=None,kind='from',args=None,query=None):
 d={'kind':kind,'name':name,'result':{'data':data,'error':error}}
 if args is not None:d['args']=args
 if query is not None:d['query']=query
 return d
def rpc(name,data=None,args=None,error=None):return db(name,data,error,'rpc',args)
def case(name,path,method='GET',role='ADMINISTRATIVE',steps=None,body=None,response=None,status=200,query='',params=None,form=None):
 c={'name':name,'path':path,'method':method,'role':role,'params':params or {},'query':query,'steps':steps or [],'expected':{'status':status,'json':response if response is not None else {'ok':True,'data':[]}}}
 if body is not None:c['body']=body
 if form is not None:c['form']=form
 cases.append(c);return c
patient={'id':ids['patient'],'carnet':'SYN-0001','registration_code':'SYN-REG-0001','given_names':'Paciente','family_names':'Sintético','birth_date':None,'phone':None,'email':None,'academic_status':'ACTIVE','created_at':t,'updated_at':t,'academic_enrollment':[]}
patient_dto={'id':ids['patient'],'carnet':'SYN-0001','registrationCode':'SYN-REG-0001','givenNames':'Paciente','familyNames':'Sintético','fullName':'Paciente Sintético','birthDate':None,'phone':None,'email':None,'academicStatus':'ACTIVE','createdAt':t,'updatedAt':t,'career':None,'enrollment':None}
staff={'id':ids['staff'],'staff_specialty':[]};ap={'id':ids['appointment'],'patient_id':ids['patient'],'status':'SCHEDULED','appointment_type':'INITIAL','referral_id':None}
params={'patientId':ids['patient'],'requestId':ids['request'],'appointmentId':ids['appointment'],'encounterId':ids['encounter'],'documentId':ids['document']}
filters={'from':None,'to':None,'specialtyId':None,'encounterType':None,'diagnosis':None,'allergies':[],'histories':[],'habitTerms':[],'positiveHabits':[],'search':None}
blank={'schemaVersion':1,**{k:{'status':'UNKNOWN','items':[]} for k in ['allergies','personalConditions','surgeries','medications','familyHistory']},'habits':{'diet':'','physicalActivity':'','tobacco':'','alcohol':''}}
case('me-user','/api/me',role='STUDENT',response={'ok':True,'user':{'id':ids['profile'],'email':'synthetic@example.invalid','name':'Usuario Sintético','role':'estudiante','clinicalRole':'STUDENT'}})
case('health','/api/health/supabase',role=None,steps=[{'kind':'from','name':'specialty','result':{'count':5,'error':None}}],response={'ok':True,'service':'supabase','enabledSpecialties':5})
case('careers','/api/careers',role=None,steps=[db('career',[{'id':ids['career'],'code':'SYN','name':'Carrera Sintética'}])],response={'ok':True,'data':[{'id':ids['career'],'code':'SYN','name':'Carrera Sintética'}]})
case('specialties','/api/specialties',steps=[db('specialty',[])])
case('my-specialties','/api/my-specialties',role='SPECIALIST',steps=[db('staff_member',{'staff_specialty':[{'specialty':[{'id':ids['specialty'],'code':'GYNECOLOGY','name':'Especialidad Sintética'}]}]})],response={'ok':True,'data':[{'id':ids['specialty'],'code':'GYNECOLOGY','name':'Especialidad Sintética'}]})
case('patients-list','/api/patients',steps=[db('patient',[patient],query=[['order',['family_names']],['limit',[100]]])],response={'ok':True,'data':[patient_dto]})
pbody={'fullName':'Paciente Sintético','carnet':'SYN-0001','registrationCode':'SYN-REG-0001','careerId':ids['career'],'academicPeriod':'2026','enrollmentStart':'2026-01-01'}
case('patients-create','/api/patients','POST',body=pbody,steps=[rpc('rpc_register_or_update_patient',ids['patient'],{'p_patient_id':None,'p_given_names':'Paciente','p_family_names':'Sintético'})],response={'ok':True,'data':{'id':ids['patient']}},status=201)
detail=dict(patient_dto);detail.pop('givenNames');detail.pop('familyNames')
case('patient-detail','/api/patients/[patientId]',steps=[db('patient',patient)],params=params,response={'ok':True,'data':detail})
case('patient-patch-clears-contact','/api/patients/[patientId]','PATCH',body={},params=params,steps=[db('patient',patient),rpc('rpc_register_or_update_patient',ids['patient'],{'p_patient_id':ids['patient'],'p_phone':None,'p_email':None,'p_birth_date':None})],response={'ok':True,'data':{'id':ids['patient']}})
for method in ['GET','PUT']:case('legacy-'+method,'/api/patients/[patientId]/initial-history',method,role=None,response={'ok':False,'error':'La ficha de revisión se registra durante la cita médica.'},status=410)
case('patient-referrals','/api/patients/[patientId]/referrals',params=params,steps=[rpc('rpc_list_patient_referrals_for_appointment',[])])
case('admin-referrals','/api/administrative/referrals',steps=[rpc('rpc_list_referrals_for_administration',[])])
case('request-list','/api/appointment-requests',role='STUDENT',steps=[db('appointment_request',[])])
case('request-create-student','/api/appointment-requests','POST',role='STUDENT',body={},steps=[rpc('rpc_create_initial_appointment_request',ids['request'])],response={'ok':True,'data':{'id':ids['request']}},status=201)
for typ in ['INITIAL','SPECIALTY','REFERRAL']:
 case('request-create-admin-'+typ,'/api/appointment-requests','POST',body={'patientId':ids['patient'],'appointmentType':typ,'referralId':ids['referral'],'specialtyId':ids['specialty']},steps=[rpc('rpc_create_appointment_request_for_patient',ids['request'],{'p_appointment_type':typ})],response={'ok':True,'data':{'id':ids['request']}},status=201)
case('request-cancel','/api/appointment-requests/[requestId]','PATCH',body={'action':'cancel'},params=params,steps=[rpc('rpc_cancel_appointment_request',args={'p_reason':None})],response={'ok':True,'data':None})
case('request-assign','/api/appointment-requests/[requestId]/assign','POST',body={'slotId':ids['slot']},params=params,steps=[rpc('rpc_assign_appointment_request',ids['appointment'],{'p_request_id':ids['request'],'p_slot_id':ids['slot']})],response={'ok':True,'data':{'appointmentId':ids['appointment']}})
for action,r in [('check-in','rpc_check_in_appointment'),('no-show','rpc_mark_appointment_no_show')]:case(action,'/api/appointments/[appointmentId]/'+action,'POST',body={},params=params,steps=[rpc(r)],response={'ok':True,'data':None})
case('availability-published','/api/availability-slots',query='initial=true',steps=[db('availability_slot',[],query=[['eq',['status','PUBLISHED']],['is',['specialty_id',None]],['limit',[100]]])])
case('availability-manage','/api/availability-slots',role='REVIEW_DOCTOR',query='manage=true&from=2026-10-11&to=2026-10-11',steps=[db('staff_member',staff),*[db(n,[]) for n in ['availability_schedule','availability_recurring_block','availability_block','availability_slot','appointment']]],response={'ok':True,'data':{'schedules':[],'recurringBlocks':[],'dateBlocks':[],'slots':[],'appointments':[]}})
case('availability-rules','/api/availability-slots','POST',role='REVIEW_DOCTOR',body={'rules':[]},steps=[rpc('rpc_replace_my_availability_schedule',0,{'p_rules':[],'p_recurring_blocks':[]})],response={'ok':True,'data':{'generatedSlots':0}})
case('availability-date-block','/api/availability-slots','POST',role='REVIEW_DOCTOR',body={'dateBlock':True,'blockDate':'2026-10-12','label':'Bloqueo sintético'},steps=[rpc('rpc_create_my_availability_block',ids['slot'],{'p_starts_at':None,'p_ends_at':None})],response={'ok':True,'data':{'id':ids['slot']}},status=201)
case('availability-slot','/api/availability-slots','POST',role='REVIEW_DOCTOR',body={'startsAt':'2026-10-12T12:00:00Z','endsAt':'2026-10-12T12:30:00Z','capacity':'1'},steps=[rpc('rpc_publish_availability_slot',ids['slot'],{'p_capacity':1,'p_specialty_id':None})],response={'ok':True,'data':{'id':ids['slot']}},status=201)
case('availability-delete','/api/availability-slots','DELETE',role='REVIEW_DOCTOR',query='blockId='+ids['slot'],steps=[rpc('rpc_delete_my_availability_block')],response={'ok':True,'data':None})
case('medical-appointments','/api/medical/appointments',role='REVIEW_DOCTOR',steps=[db('staff_member',staff),db('appointment',[])])
for existing in [None,{'id':ids['encounter'],'status':'DRAFT'}]:
 steps=[db('staff_member',staff),db('appointment',ap),db('clinical_encounter',existing)]
 if existing is None:steps.append(rpc('rpc_open_encounter',ids['encounter'],{'p_patient_id':ids['patient'],'p_appointment_id':ids['appointment']}))
 case('start-'+('new' if existing is None else 'reuse'),'/api/medical/appointments/[appointmentId]/start','POST',role='REVIEW_DOCTOR',params=params,steps=steps,response={'ok':True,'data':{'encounterId':ids['encounter'],'status':'DRAFT'}},status=201 if existing is None else 200)
case('medical-patient-empty','/api/medical/patients/[patientId]',role='REVIEW_DOCTOR',params=params,steps=[db('staff_member',staff),db('patient',patient),*[db(n,[]) for n in ['clinical_encounter','referral','appointment','clinical_document']],rpc('rpc_get_clinical_background',{'current':None,'encounter':None})],response={'ok':True,'data':{'patient':{k:v for k,v in detail.items() if k in ['id','carnet','registrationCode','fullName','birthDate','phone','email']},'intake':None,'clinicalBackground':None,'encounters':[],'diagnoses':[],'referrals':[],'appointments':[],'documents':[]}})
case('background-read','/api/medical/patients/[patientId]/clinical-background',role='REVIEW_DOCTOR',params=params,steps=[rpc('rpc_get_clinical_background',{'current':None,'encounter':None})],response={'ok':True,'data':{'current':None,'encounter':None}})
bg={'id':ids['background'],'versionNo':1,'data':blank,'verificationStatus':'CONFIRMED','recordedAt':t,'recordedBy':'Usuario Sintético','changeReason':'Caso sintético'}
case('background-save','/api/medical/patients/[patientId]/clinical-background','PATCH',role='REVIEW_DOCTOR',params=params,body={'changeReason':'Caso sintético','data':{}},steps=[rpc('rpc_save_clinical_background',bg,{'p_expected_version':0,'p_encounter_id':None,'p_data':blank})],response={'ok':True,'data':bg})
for role,func,data in [('REVIEW_DOCTOR','rpc_finalize_initial_encounter',{'encounterId':ids['encounter'],'referralId':None}),('SPECIALIST','rpc_finalize_specialty_encounter',None)]:
 case('finalize-'+role,'/api/medical/encounters/[encounterId]/finalize','POST',role=role,params=params,body={'chiefComplaint':'Caso sintético','assessment':'Evaluación sintética','specialtyHistory':{'specialtyCode':'GYNECOLOGY'}},steps=[rpc(func,data,{'p_chief_complaint':'Caso sintético','p_assessment':'Evaluación sintética'})],response={'ok':True,'data':data})
case('document-upload','/api/medical/documents','POST',role='REVIEW_DOCTOR',form={'patientId':ids['patient'],'encounterId':ids['encounter'],'documentType':'OTHER','file':{'name':'synthetic.pdf','type':'application/pdf','content':'%PDF-1.4 synthetic fixture'}},steps=[rpc('rpc_create_document_upload',[{'document_id':ids['document'],'object_path':'synthetic/file.pdf'}]),db('clinical-documents',kind='storage-upload'),rpc('rpc_finalize_document_upload',args={'p_document_id':ids['document']})],response={'ok':True,'data':{'id':ids['document']}},status=201)
case('document-download','/api/medical/documents/[documentId]/download',role='REVIEW_DOCTOR',params=params,steps=[db('clinical_document',{'bucket':'clinical-documents','object_path':'synthetic/file.pdf'}),db('clinical-documents',{'signedUrl':'https://example.invalid/synthetic/file.pdf?token=SYNTHETIC'},kind='storage-sign',args=['synthetic/file.pdf',60])],response={'ok':True,'data':{'url':'https://example.invalid/synthetic/file.pdf?token=SYNTHETIC'}})
case('report-empty','/api/reports/clinical',steps=[rpc('rpc_clinical_report',[],{'p_filters':filters})],response={'ok':True,'data':[],'filters':filters})
case('report-export-record','/api/reports/clinical','POST',body={'format':'CSV','rowCount':0},steps=[rpc('rpc_log_clinical_report_export',ids['export'],{'p_filters':{},'p_purpose':'Gestión clínica','p_row_count':0})],response={'ok':True,'data':{'id':ids['export']}},status=201)
# Generate guard cases for every guarded method, using no database steps.
inventory=json.loads((out/'http-inventory.json').read_text())
for r in inventory:
 if r['authorization']=='route-role-guard':
  for name,role,status,error in [('anonymous',None,401,'unauthenticated'),('forbidden',next((x for x in ['STUDENT','ADMINISTRATIVE','REVIEW_DOCTOR','SPECIALIST'] if x not in r['roles']),None),403,'forbidden')]:
   if name=='forbidden' and role is None:continue
   case(name+'-'+r['method']+'-'+r['path'],r['path'],r['method'],role=role,body={},params=params,response={'ok':False,'error':error},status=status)
case('me-anonymous','/api/me',role=None,response={'ok':False,'error':'unauthenticated'},status=401)
errors=[('/api/appointment-requests','POST','ADMINISTRATIVE',{},'Selecciona un estudiante para crear la solicitud.',400),('/api/appointment-requests','POST','STUDENT',{'patientId':ids['patient']},'Una estudiante sólo puede solicitar su propia atención.',403),('/api/appointment-requests','POST','STUDENT',{'appointmentType':'SPECIALTY'},'La estudiante sólo puede solicitar una revisión inicial.',403),('/api/appointment-requests/[requestId]','PATCH','STUDENT',{},'Acción no válida.',400),('/api/appointment-requests/[requestId]/assign','POST','ADMINISTRATIVE',{},'Selecciona un cupo.',400),('/api/patients','POST','ADMINISTRATIVE',{},'Completa nombre, carnet, código, carrera y período académico.',400),('/api/medical/patients/[patientId]/clinical-background','PATCH','REVIEW_DOCTOR',{},'Indica el motivo de actualización.',400),('/api/medical/encounters/[encounterId]/finalize','POST','REVIEW_DOCTOR',{},'El motivo de consulta y la evaluación son obligatorios.',400),('/api/reports/clinical','POST','ADMINISTRATIVE',{},'Exportación inválida.',400)]
for i,(path,method,role,body,error,status) in enumerate(errors):case('validation-'+str(i),path,method,role=role,body=body,params=params,response={'ok':False,'error':error},status=status)
for code,status in [('42501',403),('23505',409),('40001',409),('P0002',404),('23514',400),('22023',400)]:case('sqlstate-'+code,'/api/patients',steps=[db('patient',error={'code':code,'message':'Error sintético'})],response={'ok':False,'error':'Error sintético','code':code},status=status)
for i,(q,msg) in enumerate([('from=2026-11-01&to=2026-10-01','El período no es válido.'),('encounterType=BAD','Tipo de atención inválido.'),('positiveHabits=%5B%22bad%22%5D','Hábito inválido.')]):case('report-validation-'+str(i),'/api/reports/clinical',query=q,response={'ok':False,'error':msg},status=400)
case('health-database-error','/api/health/supabase',role=None,steps=[db('specialty',error={'code':'SYNTHETIC'})],response={'ok':False,'service':'supabase','error':'database_unavailable'},status=503)
case('careers-error-exception','/api/careers',role=None,steps=[db('career',error={'message':'Error sintético','code':'42501'})],response={'ok':False,'error':'Error sintético'},status=400)
case('start-invalid-status','/api/medical/appointments/[appointmentId]/start','POST',role='REVIEW_DOCTOR',params=params,steps=[db('staff_member',staff),db('appointment',{**ap,'status':'ATTENDED'})],response={'ok':False,'error':'Esta cita ya no puede iniciarse.'},status=409)
case('patient-not-found','/api/patients/[patientId]',params=params,steps=[db('patient')],response={'ok':False,'error':'Estudiante no encontrado.'},status=404)
# All mocked results explicitly synthetic, never claimed as deployed/database captures.
(out/'fixtures/cases.json').write_text(json.dumps({'provenance':'synthetic expected fixtures, manually specified from repository code; SQL/Storage results are mocks','clock':t,'ids':ids,'cases':cases},ensure_ascii=False,indent=2)+'\n')
print(len(cases),'synthetic route cases')
