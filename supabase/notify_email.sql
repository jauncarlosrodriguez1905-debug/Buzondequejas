-- ============================================================================
-- Buzón de denuncias · JBI Interiors — Aviso por correo al recibir un reporte
-- ============================================================================
-- QUÉ HACE:
--   Cuando entra un reporte nuevo al buzón, Supabase manda un correo
--   profesional al personal que atiende ese destino:
--     destino JAVID -> Ruby Arriola <rarriola@javidmexico.com>
--     destino RH/DO -> Alejandro Castro <AlejandroCastro@JBI-Interiors.com>
--                      y Berenice Higuera <berenice.higuera@javidmexico.com>
--   El correo lleva SOLO folio, fechas y el enlace al tracker. NUNCA el
--   contenido de la denuncia: eso solo se ve dentro del tracker, con
--   cuenta autorizada (así se mantiene el anonimato).
--
-- CÓMO SE MANDA (sin servidor propio):
--   Un trigger AFTER INSERT en public.casos llama a la API de SendGrid
--   con pg_net. SendGrid gratis: 100 correos al día, de sobra para esto.
--   No se necesita acceso al DNS de ningún dominio: SendGrid permite
--   verificar UN correo remitente (te mandan un enlace a ese buzón y
--   listo). El remitente es el correo que verifiques.
--
-- PASOS (una sola vez, en orden):
--   1. Crea una cuenta gratis en SendGrid (sendgrid.com) y verifica un
--      correo remitente: Settings > Sender Authentication > Verify a
--      Single Sender (te llega un enlace a ese correo, ábrelo).
--   2. En SendGrid crea una API Key: Settings > API Keys > Create API
--      Key, con permiso "Mail Send". Cópiala, solo se muestra una vez.
--   3. En Supabase > SQL Editor corre estas 3 líneas CON TUS VALORES
--      (la clave y el remitente son secretos: NO los subas a GitHub ni
--      los pases por chat):
--        select vault.create_secret('PEGA_AQUI_TU_API_KEY_DE_SENDGRID',
--          'buzon_sendgrid_key', 'API key SendGrid para avisar de nuevos reportes');
--        select vault.create_secret('tu-correo-verificado@ejemplo.com',
--          'buzon_sender_email', 'Remitente verificado en SendGrid');
--        select vault.create_secret('https://jauncarlosrodriguez1905-debug.github.io/Buzondequejas/tracker.html',
--          'buzon_tracker_url', 'Enlace al tracker');
--   4. Corre TODO este archivo en el SQL Editor.
--   5. Prueba: manda un reporte de prueba desde el buzón y revisa que
--      llegue el correo. Si no llega, revisa la respuesta guardada:
--        select status_code, content from net._http_response
--        order by created desc limit 3;
--
-- SEGURIDAD:
--   La clave vive solo en Supabase Vault, nunca en este archivo ni en
--   GitHub. Si el aviso falla por lo que sea, el reporte NO se pierde:
--   el trigger traga el error y el caso se guarda igual.
-- ============================================================================

create extension if not exists pg_net;
create extension if not exists supabase_vault;

create or replace function public.notify_new_case()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_sender text;
  v_tracker text;
  v_to jsonb;
  v_subject text;
  v_text text;
  v_html text;
  v_payload jsonb;
begin
  -- Secretos en Vault. Si faltan, no se manda nada y el caso se guarda igual.
  select decrypted_secret into v_key
    from vault.decrypted_secrets where name = 'buzon_sendgrid_key' limit 1;
  select decrypted_secret into v_sender
    from vault.decrypted_secrets where name = 'buzon_sender_email' limit 1;
  select decrypted_secret into v_tracker
    from vault.decrypted_secrets where name = 'buzon_tracker_url' limit 1;

  if v_key is null or v_sender is null then
    return new;
  end if;
  if v_tracker is null or btrim(v_tracker) = '' then
    v_tracker := 'https://jauncarlosrodriguez1905-debug.github.io/Buzondequejas/tracker.html';
  end if;

  -- Destinatarios según el destino del caso.
  if new.destino = 'JAVID' then
    v_to := jsonb_build_array(
      jsonb_build_object('email', 'rarriola@javidmexico.com', 'name', 'Ruby Arriola')
    );
  else
    v_to := jsonb_build_array(
      jsonb_build_object('email', 'AlejandroCastro@JBI-Interiors.com', 'name', 'Alejandro Castro'),
      jsonb_build_object('email', 'berenice.higuera@javidmexico.com', 'name', 'Berenice Higuera')
    );
  end if;

  v_subject := 'Nuevo reporte anónimo ' || new.folio || ' · Buzón JBI Interiors';

  v_text := 'Buzón de denuncias · JBI Interiors' || chr(10) || chr(10)
    || 'Se recibió un nuevo reporte anónimo.' || chr(10) || chr(10)
    || 'Folio: ' || new.folio || chr(10)
    || 'Destino: ' || new.destino || chr(10)
    || 'Fecha de recepción: ' || coalesce(new.fecha_recepcion::text, current_date::text) || chr(10)
    || 'Fecha límite de cierre: ' || coalesce(new.fecha_cierre_meta::text, 'a 10 días') || chr(10) || chr(10)
    || 'El contenido del reporte solo puede consultarse en el tracker con su cuenta autorizada.' || chr(10)
    || 'Tracker: ' || v_tracker || chr(10);

  v_html := '<table role="presentation" cellpadding="0" cellspacing="0" width="100%" style="background:#f2f4f7">'
    || '<tr><td align="center" style="padding:24px 0">'
    || '<table role="presentation" cellpadding="0" cellspacing="0" width="560" style="background:#ffffff;font-family:Arial,sans-serif;color:#222222">'
    || '<tr><td style="background:#0a1c30;padding:20px 24px">'
    || '<table role="presentation" cellpadding="0" cellspacing="0"><tr>'
    || '<td><table role="presentation" cellpadding="0" cellspacing="0"><tr>'
    || '<td style="background:#ffffff;color:#8dc540;font-size:26px;font-weight:bold;padding:8px 12px">J</td>'
    || '<td style="width:4px"></td>'
    || '<td style="background:#ffffff;color:#8dc540;font-size:26px;font-weight:bold;padding:8px 12px">B</td>'
    || '<td style="width:4px"></td>'
    || '<td style="background:#ffffff;color:#8dc540;font-size:26px;font-weight:bold;padding:8px 12px">I</td>'
    || '</tr></table></td>'
    || '<td style="padding-left:16px;color:#ffffff"><div style="font-size:20px;font-weight:bold">JBI Interiors</div><div style="font-size:13px;color:#8dc540">Buzón de denuncias · Planta JNO</div></td>'
    || '</tr></table></td></tr>'
    || '<tr><td style="padding:24px">'
    || '<h2 style="margin:0 0 8px 0;font-size:18px;color:#0a1c30">Se recibió un nuevo reporte anónimo</h2>'
    || '<p style="margin:0 0 16px 0;font-size:14px">Este es un aviso automático. El contenido del reporte solo puede consultarse en el tracker con su cuenta autorizada.</p>'
    || '<table role="presentation" cellpadding="8" cellspacing="0" width="100%" style="background:#f7f9fb;font-size:14px">'
    || '<tr><td style="color:#666666">Folio</td><td><strong>' || new.folio || '</strong></td></tr>'
    || '<tr><td style="color:#666666">Destino</td><td>' || new.destino || '</td></tr>'
    || '<tr><td style="color:#666666">Fecha de recepción</td><td>' || coalesce(new.fecha_recepcion::text, current_date::text) || '</td></tr>'
    || '<tr><td style="color:#666666">Fecha límite de cierre</td><td>' || coalesce(new.fecha_cierre_meta::text, 'a 10 días') || '</td></tr>'
    || '</table>'
    || '<table role="presentation" cellpadding="0" cellspacing="0" style="margin:20px 0 8px 0"><tr><td style="background:#8dc540;padding:12px 24px"><a href="' || v_tracker || '" style="color:#0a1c30;font-size:15px;font-weight:bold;text-decoration:none">Abrir el tracker</a></td></tr></table>'
    || '</td></tr>'
    || '<tr><td style="background:#0a1c30;color:#9fb0c3;font-size:12px;padding:14px 24px">Documento de JBI Interiors — Buzón de denuncias. Este correo es solo un aviso; no incluye el contenido del reporte.</td></tr>'
    || '</table></td></tr></table>';

  v_payload := jsonb_build_object(
    'personalizations', jsonb_build_array(jsonb_build_object('to', v_to)),
    'from', jsonb_build_object('email', v_sender, 'name', 'Buzón de denuncias · JBI Interiors'),
    'subject', v_subject,
    'content', jsonb_build_array(
      jsonb_build_object('type', 'text/plain', 'value', v_text),
      jsonb_build_object('type', 'text/html', 'value', v_html)
    )
  );

  perform net.http_post(
    url := 'https://api.sendgrid.com/v3/mail/send',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || v_key,
      'Content-Type', 'application/json'
    ),
    body := v_payload
  );

  return new;
exception when others then
  -- El aviso nunca debe impedir que el reporte se guarde.
  return new;
end;
$$;

drop trigger if exists notify_new_case on public.casos;
create trigger notify_new_case
  after insert on public.casos
  for each row execute function public.notify_new_case();
