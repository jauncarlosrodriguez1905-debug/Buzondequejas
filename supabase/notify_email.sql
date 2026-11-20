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
  -- Logo JBI incrustado (base64): el correo no depende de ningún enlace externo.
  v_logo_b64 text := 'iVBORw0KGgoAAAANSUhEUgAAAMgAAADICAIAAAAiOjnJAAAQAElEQVR4Aex8+ZMcx5Xee5lZVV3dc+IiQICQKN4AJVIUL4mHDkPSai9LsdoIr0O7jg05whG2/wH/D/avGxsOx1qrJR22Y1fa9V6SSEk8JFIU72t53yTuYzDTRx2Z+fxl9WAACj0kBpie7sFU8nXWy6yqzPe+91VmVtaA6r/98ku11AisOgKK6lQjMAQEamINAdS6SaKaWDULhoJATayhwFo3WhOr5sBQEKiJNRRYx7DRNTapJtYaA75RuquJtVEivcZ+1sRaY8A3Snc1sTZKpNfYz5pYawz4RumuJtZGifQa+1kTa40BP93dxa3VxLq44zsy72pijQz6i7vjmlgXd3xH5l1NrJFBf3F3XBPr4o7vyLyriTUy6C/ujmtinY5vra0iAjWxVhHMuqnTCNTEOo1Fra0iAjWxVhHMuqnTCNTEOo1Fra0iAjWxVhHMuqnTCNTEOo1Fra0iAmNNrFX0s25qjRGoibXGgG+U7mpibZRIr7GfNbHWGPCN0l1NrI0S6TX2sybWGgO+UbqribVRIr3Gfq6MWGtsXN3d+kWgJtb6jd1YW14Ta6zDs36Nq4m1fmM31pbXxBrr8Kxf42pird/YjbXlNbHGOjwjM+6CO66JdcEQ1g0MQqAm1iBU6roLRqAm1gVDWDcwCIGaWINQqesuGIGaWBcMYd3AIARqYg1Cpa67YARqYl0whGvTwHrrpSbWeovYOrG3JtY6CdR6M7Mm1nqL2DqxtybWOgnUejOzJtZ6i9g6sbcm1joJ1HozsybW+Uasvu8jEaiJ9ZHw1CfPF4GaWOeLXH3fRyJQE+sj4alPni8CNbHOF7n6vo9EoCbWR8JTnzxfBGpinS9y9X0ficBFRKyP9LM+ucYI1MRaY8A3Snc1sTZKpNfYT6VcKhJZRaW2pSmtLoWtEl/6hZJyVHaoyI31UZm74zpeKFnGSlScKJ0wRYpjKM6YbkQntfO+8N56R96pSigUfTEq4wvyAyVTqU1aXWJrOJ1qRokpy7IRxSVzMFWVpcoqKUOxXznUEITuipJd1Z0ERRUwwMVlPG1Miy0XTqxHCv7wcnxVxH7guTRtxXGstWZmJcp7Jol8oUnKsRKbdZztAmpxeVl0i2LBZm1XzseGK6HYLEmoGSvjYYz37bJYENcreu2s07ZFHnwBCRdxtrimkiVlDfB3JOgOOaSvlGXGRdcVmcUDClJEkW6k8cREayB5UKnwI5aQL/7AQVSqTqeHVOQ5qKTZJNycjLelemtLN8dKIjKpSiEJJdAbbFoNM9Vq+EIqIcTolISaURnfVOlAmUhNomSq0Yg5Mg44J03dNBKdsjM9Sxk2/hMtjU5bp/qFguJEyjORbxmfGDYYY4qy1+7NtbO5RdacdQCHHBEGLX+aXoJKFUdJE97iEMeu9GUHo/Ck70xTZ3KshLNJ7k1Kd8K3J1V3wthpXTQpM1Pq0kp2TPHOIGpHVbx0VMZzd2qgqEyX89KgWVPOUG9K9Wa4N1PMpdSeCKa2gfYUdaYoKJPUr+xMhlNDytvoa5pCDqUvocjtCd9pcBFrH0dKG6N0rPFM0DJJEftArJBXl1SsIlGKtGLN5HEF5tWYJ3Zvue6KHTddte2uc5U1ufLq7Xdeuf2uK7fffdWld12760tXbr9te+uaptu+Nb2hkhu3Nj8dJL2xKt4wVsbDmE2N3ZO861Nbbrl2xxevCvKlqy/98hVb7rzqkrtx9qpLgPadV227s1LuWqwcKrChx35HX7xq2xcXe7zkrqt33fqpbZ/Z1NoZUzOsXZ0TcVhqVaQZkKkPs2pxHiTCSp6wiiyzHLdr0rOtS/Zeefst133t9r3/eqzk1j2/d9ue3/38nm/e+ek/+Pzeb9501b7dW26Yinbt+9wf7/vcd/bdDPnjfTdDvhOKn/vjsTIexuzeunfb5JV7PnnHzXt+67Y9v3/btd+84/o/+PxnvnX7ngrnPd/ENUH6Sr9yqCHY863b937r9pCj629WSih+Ye/vfPbaL+7eem2kWmUGbrjC+rwsB3CqqlKBWIRB64xlljBOTUxMpVi6KNKsyBK7qGlmG7R5ijG5jJFMqB0t2t7kS4LQllRtVrZZLJCR6SB+2riZIFCqmpHZrzAXD5DIpUUbr0VT8GKCtjdoW0qXTEeXTeH6PtS0cwrS15cq+8Wh5DunsHhYXEhcOgUFRd7ZpO0tvR3wapcyxc10cnJyKm1O0DJJDa4X1e12s25e5oUSUsoYLLo4JYpJxks0RUyxLVVZMOEpkCjmKNFRxK0gqhXpRhAoVc2o7BcXDZTExFLivTvSFItErtAkRizyCmcAToaCVMU1AB99hV5MWARhHSQmIBYq05gmEz2hONEB88g67vVyWiapUinsJGjxxtvIO+NJV8ssZxxWadSc6jjPhnF7i2ZTt4XHLflUkdbKxpFhijWn870FTgpPPe/JWxK8MgvMtxTQiUZlvtasQ4qUChLMUJZ1kev5kjtk2BGDWHGsxImOYDBEkUQkaSWoUqgKNw7zh+V1NYnBnErIhaIo4yPNiWOazxcoVbkvnGXNTZg0UIKtRMiXBJf50BaOF4Fw34fArL62HnLgP35mBiQtsaVqYUTsg458GUvBp+pMWFfh+Qh3E0m4p6pezxk898H+vk9wKiwlQ8WY/RCCvhCx0GJaUhbLY3AApYTCwGop0KsaycJ4RkQDrINL/VqwSlMYuijchvvpYkoVw8bTof4jHWw7FYswDIyfwcEqS+HhlJCjCJIgD5YP+CnCOSyq+hKIBZc8cTHg2nVW5SmMUktGo+iJl4pjo4TVMcxSZxjkKcTvjIp1qC75AwXrf+REYOLyQxytm3RGePDwBLPxqIXDmP2AOQTcWrILdmKiWSqOh4Khh/B+2jcV8xsEr64oDjZv6QSug2/9oqcwiQ6+YZ3VwqdFi/3icewOwBzSN6sycvEx6NeMTw5WMQnIhAEIen/hhHywhX2XllhVxSE4hodm8A3rp1bCLA9zg0+C47qSimFjZXGAsE8p5KAXOAOlz58BhuI0znmvSq9yp0rHqqS0pInEEiR22NbyYQDj0hGusRTWYbjlXEWWSV4sBIuJPOsiJ/FBMAWHTTkYim8FqFHY+XSOifBlSgamMgzRSjEcKcmXMIuUKYW9j5hYYa+ISVzsbIpdIrRLhD09R6TEB/Gu+mut0Gm/L3G+wKd763Ihh49aPpjlPBWesiqHzl5U5tsllYDDkipIZaI6PghaXkaqzs/KnOp6whzTTKiRYGOILOz0NMnLJBEeKHBkfiGHMZnH5h1WlwBEUeWXL0rx6IRCJkpEOYd8IJyyjPFKKSxQLfG8SIedV04bcrHqneXQYoVaPK75AVRQjBFVCVAV0+2Uva7tdVzeozyzZeG8E+f6ZgEUSF8fWs6ktIdomGWU0dhuxYZmRF5IKkGw+go2lD0lKtXEKswNxAiHcxFJY2RwEgLfSDST91II2aLsOlcUXTy0xDrCE0agjFLOCxzCw4HiUGVkSAjGDEKsVNJo4I07beHLZCNNG0mDkkZs4gbgUIa0IaUROL96KJzlMqNxS3gRY8tVN6AWkSZSCgFho8ig5nSOEwwyReyVImayEVvtMynaZJd9gmnYyRNYRVRqJYokjiJtTNxsOl86gXfoXuHHDLB9HHnoQ5XQ2VA7WK5xIUwo4aQjKhxlpWCKyoQ6ljKxZajIrBDQopBWFwgOTVYZrCDyxA5dZXneK7qOvBVXOmsd5QWFo7MOJetD7izGUWfJF1L2nMMVuFMkiuIkTrWKQssj+ZVkdMOCReKEbOYyzONZlpece+1LwjiFxxiWQSmJgDr0IcrIiOWs2BKrATxMNpeTLj4pasHpEypps5oHwYgz4aJwWCEUhfWrh8EZLgduebAK3Cqx9mp4H4NOpefCa0hOSUlRTqYgg7wvRaiJS04kaimV4Pac2BLoJpo8JvfVs3RFLSliRZaw5sRqOCOd+6hQTVtQO5hHNne5F2+tz/PcLv/nLivq8yMuVh9xbsinQtci1tL8kblXD5549oP2Yx+0f/V++7G3Tz66v/3Mgn/fEpYIWNFEWjWGYEwYasKIBVqwPWrfevvYc28efvqtk0++Offr1489+saJR9468cjLx37x8vGHXz6OvC8Ph5qjD787/8yB7KWT9F5Bxxy1xbjClZ1uOQQ7z6nJksRx/t7RV9498fy7vWfeXnji7ZO/fnvuifcPv9qjE47wbJZOWOvIcKIUJvpzava8LwrRPe+bL+RGo0nHRjifyz548bUHf/n03zzw+D0///Vf3P/I//zxw9976PEfvP7Ok+38qLDXkdZqFacYDFPqlOWewvyA3D320j8+8sLfPfTs/33o2f/90HP3Pvjs9x967i8ffuEvH3jx+w+88P0HXvyrB6Agf+GeqnjPPzz23x949q8ee/Vvnzt4//7sxZxOUOySqVW085SN53a05ti8e+f5N3/2yPM/ePDJe372xF/++LH/8c+P/PnLbzw5t7BfqJBqwagVx1GiODm3Vs//qiWIz7+J874TEdYkWK2XdLLkY2KOmuZccybjeM6pORUXSUJGqeol+bw7+dgbwSoMXWTNkZwPZLy/R+905e0ev9Gl1zP1Zp68GyRG/k4e8kWljN8/Vr76yvu/ePTZHz3y3H2vHn6uSydKKj62vyFd4NVCTkeOzr9+tPPqgn/bxu+ricM8efjQ0fcy22ESozUAJ6GA55CMOKPZNSAWuugLVfOOJ3wyYlcyFgRYQ04bSjme79AbveToHHUO04GsdTxTh4TbMRn2xhAxZisanEA8Il+hFSmOPAreKi1KKSHx+E+EmbQm5EQAdklYsElHkVRidCvLPUWxa6ieLhTeTKPEWe7aOCubnmaZtpZlM3Ourbpz6ug8vS1TJ/1st9364J32o28ce/C193/J1PbU8dLz3gq6D4xFn57I4jBY4Fp4LfUU7Kpy4AOPBl+9bG2DLndlLEkezVCP2UWbe47FlDxxVDexpPIRNVzuSXnRuSjLrAfKsh0IMVlhccpbjUnVM1aUeBNY5gaEfJkzQ65Gx30J/WDZK9gGAi2QJ+QTQpE0ES4J59fixzmrgrDjp6BY4py41MbFGDQtUU6qYCNxoiYno9lWNNNqThU9V+ZFq5VGkTp0+N1397/RpmM0slQGm2E/9xYVFVwYlTlrGLkPu8hEGDGQUSCQwbDhBZvjKfmUBAJuxUSGFpMsHod3UD3WBchE5JidkCP2JtKbom0zevMUb275TWm5Kc428fykO97U0vAFY0iLsdXGxUL3yOHjbx05/sbwDPy4lm0wngsCnxS4BV8cfPm4u4Z1Xg2r4Y9rV5FH3xwuUxRGrFgoEgGfIP2/744ocC5csQY/EcyYTMQipFQwQFycRDO3XrPv83t++47rf+eOvb9327W//dnLv7p355evueTuMuPINCMV9bKudb1kQpHpHjzxFo0sYbCHAFRYAEghuhr4URyB9O0YQcdVDEO/UMJ0zdTPByPyowAAEABJREFUSYAIk6A6nD31+43iqerVO4rHEq3itE+VTIptiWvFZtPl07ddsfn2a2fvunrzXZ++9Ms3fGLfZ6/82m3X/E4znk7NBEnksMemKUkMGdfpnaSRJVMN9pULAoYlVTEdlTkjIxYIxBgbwhTniZ0w3odLwTCOwRyrVwj5AEq4AMe1sBPr/UBoMUyxeEOSYMTicpbzGfFT7Cd93tJ2qkXbpuPtW2a2KYldSZFJ47hZ2LK0ttEcWSApAIWVQ/VYEhIUuIBRH/oIRI2gz36XAQjC0ERYzeAFkcGqnsfiIHArr5YLjiq0QoZhrH/X0HLhLiusS0qhQmm87XgBuYxqRtOJmdSUKDGKtGaYYoksk/Ge2OP9IsKgVRbemMbs5m00qoQxnWE/3jIyCm8ewLCggO1oDBodseCv4FcJxicuQSZRIacAEEDx1bkhZWc1y3kgFmitMkJe2aANGCbOlV5gmFPasiosdbJyrrvQxZCq2BRFmWWWOGpOTE9Pbz6r3TWs4DxQCsbDBehQ4MUa9n9mV6tHLLAEUrXtEIoyt7bAdg6zRZ6XhfPY/Yisx55C7DDXKPKaHHtCfIhYIuUacdmikBQJhnEM7ER4EGEj93iZRMsk7zHkyKmbwkVYlXuPhVxoEq0uiqDrUOP8ZJ5HWqJUaWW7RudsyhPtwy8WP3kn/uVb9OBL+T+/7n7yWvHjR97//v97+r+eKA4d771nkm7CKu1Nf9J8+l9d/vuX+6s8tRynokzhbTfrOieEXaOy8iVYcdYveAoPIbCoyvEqg3HwrAv7FcxwaoAQWcKrj9tEdpZ8k/DeE/7daVIAYQWkGRbECsAqIeVIyTKp38uF5/DkwhsJLSBs4VD9ToWTGV6QxtolNpHRpBlRFGdL/KoLlzI+pflTylofoyrBVJCvL0VRtNvtn/3yB//00//zo5//zcOP/ujRx3/6q6cefPWdF052j1onUZwKR8Rm247dV117w+bNnyhd4rFXK5jESWtGk0oxMXTaaEmtlsNCBDnVmkeElAakTKKYNYp4QkhQcBW9QCBI//LwGFWaEB6v8LDCKgjqGL8z2w3F4fzCkBoIJWVZekdG4/FW1rpoasHFRwp9qIyPd+nYXG9/5k82phS8U5HCKCHaNKZmdHOixHZJ1BIqCZvphKGRIxNx5QH3vRmO5ePZ6mp6LALmgD+OkZQwMchWWrIllUUImLNFxTKMXjFReKxpiUbSt2SJbUzhdjRAVeqfrdThZCCVCCN3DhkpFSz1jnJ/vJQTjtqkC2XCF3FMI45Ea/GSO+lZlZ3oHHr+9adfOYhP0R1NVmPQIrwESN9SIEK05Fe/7uLPVy1gzMDRSzULYOABLwg0I/FAWpHTBRuHwAj3+QRkl7DW1F9VhOHKk6ggOL/IuaBR0PvKsPIoSiITa40doLD+sNaDVaCYdmlC09q3pBtxnmjXkqw5f6T0RRH23VUh3J5rv/f2gWde+eDRN08+LpQRlV5sUeL9g5Cw4KSaWADi/ASDVMUtTFyOqyaEHHjWU0e7en+hD3t1rORjXXekkBPh5WURa1wLckNwj6dAO9QQgV6oGD6fQifVz3txzolnjFVE8EZjhTQ5OX3H3m/def23br/2d2+4fN+nP/GVz1359Zuu2Hf9ZXe39GxDTUQUky9JdUyz0y7eev6V++azIyAWMxpzgmcNrhAW8JY2WOpHdFWc9ogGhVGn35oXEe/9K4d+9vIH97988KevHP35S/sffOXdXxw48S8lHSUQiyvgSVGg0eJd1aGy6nQl6iq24Tg0sSEFm5Uy4BZ8aTSas7Ozu1q3Xj5z57WXfOX6XV/9zO6v3rjrq7d98nfv3vPt6z9153R8mcqb2kVaURJbT3OH5149cPDdnDAhKiTmJXP9krZBlCqEq+crM7AMdFlcbpF76qWf/Pr5f3rs2X/41bP/9Ngz//jMiw+8vf+5+fIDwtC22C9sgODGxXJ1QA2O/RzK0CUyia6SMdjpwLIdcyH2POMpdcUsxFwxG39qgnZpu4ntVEybb9xx92S83fYiJQ2x0uksFGUniuno0cNFgdmQ0FjfaEDCxH194+Rq9VxFU4opUpxQwNGXrt3Ljtv0iGt2i7Swk/PF9P5e8k4hHWM2lVh+EXe6uSHvsmOb0lTmowm3u/TvpQl7m86d6Gms+7mNj9WOjAg+Dw8QWqUknIEWzuOlME+SxOikyMVZBfOEcvFFsMU7uBcbhT0GT5tnmzuacVSWYvS2KN5pOZG07HTyZjzhcEtYbNk8z41OyzJe1ky21TCPIU0IozieN8YyFMVl71juBOYHsBkjrzEGOYZMEdHCLOFFnJaaF4QJwVqumdWpX7UOpL9sX7QKzSpMcMzaFohCTKwLK84TXs59BCzLhazds7lol1GXjfa4Qms0ojhwiJmjKLJUABXG+6P4xYaHdsBSHdxFMCCIB4JEIczot8GUKtUgnUCgoEjUsFiha3GKLIll8UzCEVPiHYBAtTI6JkJjCiarkOG4gWR4HgNTPD9RZKa0SoF7GR55sdp33PyR7vu6gYkmM0l3oXcAX3J6RcdR1i1PJCb1TkXKTE3NeLExw0LvXD7smEiVYDQ4jXFLxGMgwceDnLo96vSkm/kgUFBE5cHe6yfzw6UqKIa5npSHheLiKEqcEyatCJaTqjjVz2kjpeD86vgblu0B3Ko1NIsAaa3iLTM7YhNZ1yGTgUwZtQ/Nv/H6oSePFq8cyJ8/0H76zQNPLBQHc3dSRbnodmSaFsGKJrZu2oLRC62hrdgYKEMVpTBSChJ6EfFKe2afF91j5YvHi5eP5y8dLyoJysuofOGdBz84+Wqh2yZ1KspIdZwrnaNNs9sUpkrSGK7QFFBAXg1+1XHDZIjaavsqVYOiFMdGN7ZM74hYlUWbOYtTTIXZid67+48/+6vn/+5XL/z1U6/+/cvvPdwuD4uypkFR05Jt2Myk8XSrMaMJk4uxzlYtDjfDoIIdAsyAgpmXvNaM71FZ3v7Ro3/+40f/7J8f/bMfPxIkKI/+GSrfPfb0fPEBnhZWRenmi6KtvCQysWPHrohTIuUw5lGAV6SPyHDtH7fWg+fL2LTS6tPwBUgxFzDew6Ot6Scmo02xaHL4RcZEnopOceSDEy8cmH9h//wLXXdEGdImzYuwQe+yRPPE7OQORS0lsXfksIlNGABWas/KrgePvAMHghc4ML4csM/zbmbe7pp3kGfm3UoWi54WMKpplbhC5Z1S5Wom2rZz+powYhHGVyXCHiOfguIwq9IGS6tGLATjQ9AJMYMNenvzul2b9m6ZwJZPWrYj7SciM4GLoxbjw5qKykarqaMZxZu7nbQsJkjSbZt2777sarzGa24qlRhqSEFrkGAVh0Sn11iusCq3nFkuwB8IlFBUuVapUZPKTUsxpe3UdLzzsk03XLPzrlg1PDGR0kozLcLLoYY2VFr0fJV89me1o2aTT+6cvXLL5GVkW9mCkjI1PCE+LgkDhO+VhWArwTVJNmna3Ey2x2piy+ZLd058QnHCePSFdIyHfnXtPMtMIkyCqMWEyMxgmIhDHXIrkRdTCRRI0EOlTdg2lZuK/ExTb93Uumznlus+ueVGT2I95m5m0vgRETPTxkurFjDFCYEHQJCJVRCoEE9+dvKa6y/79g27/nBrcgVnpZQnjGp7fSznBd2IukWRl4Xv+Vna0upu/cO9/+Wu7X+U+u2TPMPkhYUUqTiEhwcldDFY2IMZVC2YiClIpYs3mKAEJ4UIWwTKMhdMme7RtJ5188bOpyltlQJLPauVTPhWSs1YxWFe1woKiqhs+smoFyfd9FLz6Vt3/dGd1/zpldtuSUglNNVU05qMpqpP5GHkNrTCVJF7BVmb3sY+XNSbbrYvncm2t4oJXXCZ2+3ljnjexdQt/QlKPCny3itxeHwGygrNXPZyteyZVTphKG7yzK6ZK6+/6rab9uzbe/nd26duaPorGsXlSW+36V4a5btm9JWXb7nxhqvuvuMz32imE0nS0OHFKlgALoXDKv6YFgNO/QQENJGZTa/bNnnDpTO37py+dfvkLdsnb90x9fmdU3de0rhpoFx/xZduuf7rd978zS/c9I1rPnnLbGsX+xQ7E/1GR5AXk029ffe2Gy7ffsuuzbdcOvXZnbM3f2LzbTt3XD3R3MrUEFEEWq2VZehsuF3ZjCxGBEmn1e6rN3/+tqu/9eUb/+QrN/3pnVf/yRf3/Lt9N373G7d89+s3f+fuz/zBLbu/cfXmLzQbrdhgTxLBXrRNhLysnpFcEJfEQow2mSQiSiB3XP3tr3z2O1+//U+/dut399307/d99j989bP/8Ws3/Kff+tx/Hih7d+3bs2PfVbOf3xZfN0GXxrQ5oemJeIZGlCbMJS2+7KbrfusLn/n2nXv/zR17/+0XP/MnX7nxu1d88nNTzV1EKYbq06aF4fx0aRjaYvCG0XS/zUZCTaMpJ58p5acm6LJLor2XtW6+buuX9mz98nWb7rxi+uadzb2zandMs8ZNUJhPFZESIsFEKOHITKuXclr8WzwhtA1+hT8OjrRPTdmMium43Nzw21LZkfgd2l/SdJcOlGn6RJMuiWhW+dRm7DLRRIppVKnokPZqKto+pXa1aPcmc80mvnqKrtwyfaWmafFYsCbwV7AGgIlh9MJhUYZxQAiH0ewZbXJJlEeGEqNjilT4+ywtOTbjp3WZuty4TJUZ+YLIsqJIAqWU895ZseGvojwR8WoGDA1CAqcIKRzRujYsSaQxWjajKFVRyqahdKoIL3cDhX1kCE+MMko34igyWA95QktocxQSGyL0L0osPo1FQNVlVLYtU4sI+4exVjCRPK4JaA497kPvoNtdyIqekFWKWYlSiAZHxmilIxNF2iBFUaSiiLQmDGpOeafEa8F3EVJExLy64UKbkN9oU3zR80W3zDtZPu98hylnwWtF19rBQuKwCgabQjyVQ9RYuzDJ0miSTi0ZqyOP3TVYkMQ6SVQjMd4rPJ6oAYoiABMwG6LfcJ9WPQHiVW/zQw02mzONxpQxTXjlrHO2xD6DwgsaW2KvDDMee413M+pZu5BlukoKA4FSlapD5Mh/qNELKqBBQwLHOcDLQpUxykwoMxklUw2TahUTOM4qjmMdDRaY4JwrwL08z0vrBOtAtMWoH4lYl3e68/ClLDHXO1dNAVqX/Vc/pQhPtZBTOjiNOXHYRqphdyDV1CZesYq1gUR4ZEgjBvDOF+JKjy9swQqMYEnaQC1EKQRWK7Vonlu8JFx2wT9DAdvFlgNr2SEemIgJbPPYqUptqSlMyoYxCCwj3sOPKE6SOElN1BCOCkeZExpR0lopo4k4ihvESEIM7KGKUsgd9uSq8ZXWJqmhd4ORCgIniSQsxrUIJvuYsNgVHZGJWKEKEolACM88hIirnELC0IV3t6Ct4AeWELwD1gpMDUJBZ4qZIg4pdMGsq5qGxCIqGMha4QGAFswlLOxLQ4PEKAwGuAaC+7RQjBwOpJcAAArPSURBVMWWAmtXYGO4FD0smgqHFREHZAiNBxMH/TTD5rOEpNGIpkQAJMN4VvAHOAd70AjhOVXKGLTviT0rTytNsIuwEGXtlXEYGJSQsoqXawY9LXeqrq8QQNQHSnWyzpZDoCbWcsiMsv4i6Lsm1scGERANlI+9cUNfAMg2tP+180NCoCbWxwKL9elA+dgbN/QFNbE2dPiH53xNrI/DVrBNMkg+7r4Nfl5hV4PCJngZPkdAAR744O/Tws0UpXZZe0JThC+sLsnF5WEv0VPYBz/XHJsoKxL0vyIx7IVUwUkPm81sre/ORC1zUis1yZziFDYGCXvr5FhctaM1uPlljQRCA2WZGwa3HmqxpaRwZCYINpUU41Nka4Zmo9Jr6hay0LNZKaYoxWFDWCxBAHXF7JAJCQ5oYpDwMokIna5AmC2zY5bF9oKxzCAH29zmZJPZ1mYlmY4XXHS80HODbAl16DIcfvPHvtlspM0kivFxgxw+Bwv8zYiK0nfGSjxlnnKlrY6wgV6Kyq30Ct/LpQMp/GJe+k4pHYv8vCTcPpwbe2WG74yOCs8FNvmZwz8qwS6k8x3bN1jgAjzKcikgw7NksWXplr63qAclKz2CXgjllvPCFc5J6RRTI9YzjXjZ/4OhIuz+BVLzGdwKz0W7M9frdfHo2PDxgkkXXXcsoyNWnVyhHLNqiLJAH3Rpf48O9PqKP+yTdjLlLc8FUXNOzZV6zvbFzA3VmPNovJBONMk5zbX9wZ4cKuholw7Nu/edPu5UEKuOeXXEqaNOHUaO4nCFT1p1ogox8hMVbseRtwGvh3kLJRXOStaVzoLvnAxUoUEJI5aquNU/KcQ+CDljNL7sxWkDX6CsKo+3D774+qOPv3TffU/eszJ56vv3DVMee/GHj738w0de+sEjL/4N8qde+/G7x55ecO/c9+S99z95b8ifuPf+J+697/F7f/r4vfc/fu9QjTmPxt858sKRzhvPvfXQky/9+Ncv/f2jr/7w1//yt48+/8P7nrzn/ifv+cmTi+j95Knv3ffU937y9F/cN0wwQ+NP/q/7gtwDA+5D74vyvV8899fPvHbfe8eez91xk1CcGPwXmzCh9anzG3mfVRW9Fs94wrzO3nHuvUWdJ4exOqf594+89MaBJw5lz65Mes8eGqa8uv/h1/Y//PrBh1458MArHzz4xqHHjnRfy6JjMPJg9uxhdF0ZfDh7FsWhWnJ+jR/pvdPlAzD79YMPvwYvPvjZ6wcffPPww4d6LxzsvXA4e67fbLA/B/JP94vDzJ8DdGfI04eyJyGvHXjorWOPH+u8UfCcigqtsQhzBlMiDU6glA4jlkA5NRti0CIf/h6k6OVlkZUFRT5uiYtPqtbJBb9/hXJwwQ9RXDJvG/OUtlWr69OOi7ouybnhYWTb75+XRWvnfVCq4hCNWVi5p9RwjVnTk+NFPEfNeZcc982Teqoz7w6jtX4eFL+/7T9YkAPQhyuhi4DVgn8/iLy7IO9BaKJNaVeSTKLSii1tYcvSW6xrlyUWTpyiFNTwZwAes2FrIkmaSRzHnsSRLXxnITvYdUckoRWKkWSIkotk1vVcWXiH9xms5DuZLHQdJdQXWMtxpSOPYfwQjTkPTzuZs6RP9nolWa9dz/d6tptLTnhtimKKDccwWFGioVOszqOLFd4CiNALcpaGSALxkni8EOYONGDvY1ap5mYaTU2my/6Nf38qpLNTL+vkeW7Fh8U7CRtHptBxWVpamZSqHKbE8ZTSDU+R6DSKJpNkOo5nVDRdWMorUwtHuaNQrJShGnMejbMJNiudNtLJpDXBJiIOkuMdzOrC6jzkpkTRSWH5PLpY2S12Kb6Coam0vnRBksZk1Jgw0QQrTF6NIte9ju925Gzm9GuU5o6mXIvXnrRnLaRFtJRRpLWOyLUitdX7KetiHUWF78TsBgupeKAwGL76Ep9qVnzJnBvOtCyQneci06VPyriJHROSBnGDdMI6VoynPdZ+6cYxUVLr7fz8lGFV9LKTRyJfGuwk+TzSnSAqj9kl5BOh1AcZttlNKVPxDVGxNCJpasJmW8oqdgXnXSlz431ixVBsqCVFtNCn0dk5llYfrhSuyqfqw3pLqhpkqDQ4rDfxRJCxtdpj4VEZ56u8nyEKfbSrKSWsgE8V++eHli8F+8weGLWqS9wjBclIQXpVsXvmZWfqMHepCL0ScAuyWO0rt31VgpNwuFLHP1t0AZYvCdFi5RhZ71mCfVi6MOivfMjxNANqrAcNBUpV1kLBOCFYJ1bFoWVACCw6s3mEnFEVKNUnUy/Qa5FkvTOvPFMHk4JfZ1ShBsMSBHU+sIptyFEKvsFbDuEJ/X9YwQXjJXABvhABFQghoYhKKGMlFcinLYKRlYgmQkzpjATAUXlGxRDUwGwm5P22lVT/ZoGAogKKMCjkEiyrFJhKA9NvnMCDAsGDshQAT+SIkON2bExEFLbpcdfZggvGSfAYwFR4T5YgQYFrMHucjCQ8pF7YV39uD50QMlkMZWUnBi986gniq/LQs8URIxgGMi0RiJRPgjjkqfKpCgr0ZDmDVHW3UKBOH3dFaC08LlCgOmK4hAuIwlC8RDga+9R/uH2wP7jgK4P7lZU6JtmibX3z+jYBeQh0Vz0SJXEZlPCEo3K4AjswXEH63SihvpCPCBOxIF+SOFT2rzsr7zuwVI0iEwiEZz3UgU+ewLngPFEYAxAYXDNQwg1j9AvW9s2BF5BKP11ZFccg8+w9lllMPijIFYLq8Wyzo7AIKUlVAm6Fohu2yWHE+nAfTMQCg4JdTBKMFei4ELmnZRIo8uFzi9CjfukOXACpahbPLp06rYyj1rcWTwUE9vWLUMZL5LQ5fQtDDrSBuSfQC/M4JCieCHL68mFo4MvZzYJbi6NmIHcZdCjBqvLsi/s1mP4SwvhG1RyHq1Ue1vyqo73SPtIu1a4VchTJarwL9O8bn5yxhII1cKQaovtjLSrhCHuShNxUECgoohLXjpNogAxxiQbUUPo4U04MDhnyE+Q2BYGCGIXK4Vof2cjABsEQZYktBiXHyjKwxXKqTxJf2QYzTIAXx0GCJ2NQdV1XI3BhCNTEujD86ruXQaAm1jLA1NUXhkBNrAvDr757GQRqYi0DTF29HALnVl8T69xwqq9aIQI1sVYIWH35uSFQE+vccKqvWiECNbFWCFh9+bkhUBPr3HCqr1ohAjWxVghYffm5IVAT69xwGuerxtK2mlhjGZb1b1RNrPUfw7H0oCbWWIZl/RtVE2v9x3AsPaiJNZZhWf9G1cRa/zEcSw9qYg0hLHWT1P8L8RqIGoHVRqAesVYb0bq9CoGaWBUMdbbaCNTEWm1E6/YqBGpiVTDU2WojUBNrtRGt26sQ2BjEqlyts7VEoCbWWqK9gfqqibWBgr2WrtbEWku0N1BfNbE2ULDX0tWaWGuJ9gbqqybWBgr2Wro6ImKtpYt1X6NAoCbWKFDfAH3WxNoAQR6FizWxRoH6BuizJtYGCPIoXKyJNQrUN0CfNbE2QJBH4eIpYo2i77rPixiBmlgXcXBH6VpNrFGifxH3XRPrIg7uKF2riTVK9C/ivmtiXcTBHaVrNbFGif4o+l6jPmtirRHQG62bmlgbLeJr5G9NrDUCeqN1UxNro0V8jfytibVGQG+0bmpibbSIr5G/NbHWCOjlu7k4z9TEujjjOnKvamKNPAQXpwH/HwAA///Os5T/AAAABklEQVQDAIUkZZC7JM/9AAAAAElFTkSuQmCC';
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
    || '<td><img src="cid:jbi-logo" width="64" height="64" alt="JBI Interiors" style="display:block"></td>'
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
    ),
    'attachments', jsonb_build_array(
      jsonb_build_object(
        'content', v_logo_b64,
        'type', 'image/png',
        'filename', 'jbi-logo.png',
        'disposition', 'inline',
        'content_id', 'jbi-logo'
      )
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
