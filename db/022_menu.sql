-- Descoberta de funcoes: /menu com botoes por area (textos aqui no banco, editaveis sem mexer no workflow)
-- e uma dica por semana (seg e qui) no resumo da manha.
-- Idempotente. Depende de 018_resumo_fase4.sql (f_summary_data com extras_text).
SET search_path TO agente, public;

-- ---------- textos do menu ----------
-- p_key: inicio | lembretes | agenda | tarefas | remedios | dinheiro | pessoas | docs | listas | projetos | resumos | ajustes | entrada
CREATE OR REPLACE FUNCTION f_menu(p_user bigint, p_key text) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE k text := lower(coalesce(btrim(p_key), 'inicio')); t text;
BEGIN
  t := CASE k
  WHEN 'lembretes' THEN
    E'Lembretes e avisos\nEu aviso na hora e você escolhe: Feito, Adiar 1h ou Adiar amanhã.\n\nTente dizer:\n- "me lembre amanhã às 9h de passar na farmácia"\n- "toda sexta às 18h me lembre de pagar a diarista"\n- "lembra nos dois de comprar pão às 18h" (aviso para você e para a outra pessoa)\n- "sempre me avise 30 min antes dos compromissos"\n- "para de me lembrar da vitamina D"'
  WHEN 'agenda' THEN
    E'Agenda (Google Agenda)\nCrio, mostro, movo e cancelo compromissos. Convites que você receber chegam aqui com Aceitar e Recusar.\n\nTente dizer:\n- "o que tenho hoje?" ou "o que tenho essa semana?"\n- "reunião sexta às 10h, me lembre 1h antes"\n- "move a reunião de sexta para 15h"\n- "cancela a reunião de amanhã"\n- "quando estou livre quinta à tarde?"\n\nMudanças e cancelamentos pedem confirmação por botão.'
  WHEN 'tarefas' THEN
    E'Tarefas (Google Tasks)\nAfazeres soltos, sem hora marcada.\n\nTente dizer:\n- "anota na lista: ligar pro contador"\n- "o que tenho nas tarefas?"\n- "conclui a tarefa do contador"\n- "o que eu concluí essa semana?"\n\nPara guardar uma ideia ou um texto livre, use as Notas: "anota a ideia ...".'
  WHEN 'remedios' THEN
    E'Remédios e estoque\nControlo quanto resta, aviso na hora de tomar e quando está acabando.\n\nTente dizer:\n- "me lembre de tomar losartana todo dia às 8h" (repito a cada 10 min até você tocar Tomei)\n- "tomei a vitamina D"\n- "comprei a vitamina D"\n- "tenho 12 na cartela"\n\nPode mandar a foto da cartela: eu leio o nome e quantos comprimidos restam. O aviso de compra vem no resumo da manhã.'
  WHEN 'dinheiro' THEN
    E'Dinheiro\nRegistro gastos e receitas e mostro para onde o dinheiro foi.\n\nTente dizer:\n- "gastei 42 no mercado" (texto, áudio, foto ou PDF do recibo)\n- "tênis 600 em 3x" ou "aluguel 1500 todo dia 5"\n- "quanto gastei esse mês?" ou "compara com o mês passado"\n- "orçamento de mercado 800" (aviso em 80% e 100%)\n- "o que tenho a pagar?" e "já paguei o aluguel"\n- "o João me deve 50"\n\nO botão Desfazer apaga o último lançamento. "Fecha dia 10" muda o dia de fechamento do mês.'
  WHEN 'pessoas' THEN
    E'Contatos, grupos e locais\nGuardo e-mails, grupos e endereços para marcar compromissos com um pedido só.\n\nTente dizer:\n- "salva o e-mail da Cláudia: claudia@x.com"\n- "cria o grupo família com Ana e Bia"\n- "o local igreja é Rua das Flores, 120"\n- "festa da igreja na sexta com a família" (uso o endereço e o grupo salvos, pergunto só a hora e confirmo antes de enviar o convite)\n\nO comando /contatos mostra tudo o que está guardado.'
  WHEN 'docs' THEN
    E'Documentos\nGuardo seus arquivos por pasta e devolvo quando você pedir. Eu guardo só o identificador do arquivo no Telegram, não o conteúdo. Até 50 MB cada.\n\nTente:\n- mandar a foto ou o PDF e dizer "guarda na pasta Casa"\n- "acha a apólice"\n- "me manda tudo da pasta Reforma"\n- "me avisa antes do alvará vencer em 20/12"'
  WHEN 'listas' THEN
    E'Listas e notas\nListas para marcar e notas de texto livre para achar depois.\n\nTente dizer:\n- "lista de mercado: arroz, café e detergente"\n- "marca o arroz" ou "comprei o café"\n- "me mostra a lista de mercado"\n- "anota a ideia da assinatura anual"\n- "o que eu anotei sobre a expansão?"\n- "minhas últimas notas"\n\nApagar ou esvaziar pede confirmação.'
  WHEN 'projetos' THEN
    E'Projetos\nTrabalhos maiores, com prazo e várias tarefas.\n\nTente dizer:\n- "novo projeto Reforma, prazo 30/11"\n- "adiciona as tarefas pintar sala e trocar piso"\n- "quebra o projeto em tarefas" (eu sugiro e você confirma)\n- "marca contratar pintor como feito"\n- "como está a reforma?"\n- "o que está atrasado?"\n\nProjetos com prazo perto aparecem no resumo da manhã.'
  WHEN 'resumos' THEN
    E'Resumos\nManhã (padrão 07:30): compromissos, tarefas, lembretes, contas, estoque e projetos. Fim do dia (20:00): o que ficou pendente e o que vem amanhã.\n\nTente dizer:\n- "resumo às 8h"\n- "desliga o resumo do fim do dia"'
  WHEN 'ajustes' THEN
    E'Ajustes\n/config mostra suas preferências. Para mudar, é só pedir:\n- "me chama de Dri"\n- "sem emojis"\n- "sempre me avise 30 min antes"\n- "avise o estoque com 7 dias"\n- "fecha dia 10"'
  WHEN 'entrada' THEN
    E'Voz, foto e PDF\nPode falar comigo como falaria com uma pessoa.\n\n- Áudio: eu transcrevo e faço o pedido.\n- Foto ou PDF de recibo, nota ou boleto: eu leio e lanço o gasto para você confirmar.\n- Foto da cartela de remédio: eu leio o nome e a quantidade.\n- Quando eu perguntar algo ("Que horas?"), responda numa mensagem só, como "às 19h".'
  ELSE
    E'O que eu faço\nToque numa área para ver o que dá para pedir, com exemplos. Você pode falar do jeito que fala no dia a dia, por texto ou áudio.'
  END;
  RETURN jsonb_build_object('text', t, 'kb', 'menu', 'rid', 0);
END $$;

-- ---------- roteamento do botao: prefixo mn ----------
DO $$
BEGIN
  IF to_regproc('agente.f_callback_pre_menu') IS NULL THEN
    ALTER FUNCTION agente.f_callback(bigint, text) RENAME TO f_callback_pre_menu;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION f_callback(p_user bigint, p_data text) RETURNS jsonb
LANGUAGE plpgsql SET search_path TO 'agente','public' AS $$
BEGIN
  IF split_part(p_data, ':', 1) = 'mn' THEN
    RETURN f_menu(p_user, split_part(p_data, ':', 2));
  END IF;
  RETURN f_callback_pre_menu(p_user, p_data);
END $$;

-- ---------- dica da semana no resumo da manha (seg e qui) ----------
CREATE OR REPLACE FUNCTION f_tip(p_user bigint) RETURNS text
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE tz text; n timestamp; tips text[] := ARRAY[
  'Você sabia? Mande a foto de um recibo e eu lanço o gasto para você confirmar.',
  'Você sabia? Diga "o local igreja é Rua das Flores, 120" uma vez e depois só "festa da igreja na sexta com a família".',
  'Você sabia? "Quebra o projeto em tarefas" e eu sugiro as tarefas para você confirmar.',
  'Você sabia? "Me manda tudo da pasta Casa" reenvia os documentos que você guardou.',
  'Você sabia? "Orçamento de mercado 800" e eu aviso quando passar de 80%.',
  'Você sabia? "Lembra nos dois de comprar pão às 18h" avisa você e a outra pessoa.',
  'Você sabia? Mande a foto da cartela do remédio e eu leio o nome e quantos comprimidos restam.',
  'Você sabia? "Quanto gastei esse mês?" mostra o resumo por categoria.',
  'Você sabia? "Marca 30 min com a contadora e manda o link" cria o convite com Meet, depois que você confirmar.',
  'Você sabia? Toque em /menu para ver tudo o que eu faço, com exemplos.'];
BEGIN
  SELECT timezone INTO tz FROM users WHERE id = p_user;
  n := now() AT TIME ZONE coalesce(tz, 'America/Sao_Paulo');
  IF extract(hour FROM n) >= 12 OR extract(dow FROM n) NOT IN (1, 4) THEN RETURN ''; END IF;
  RETURN tips[1 + (extract(doy FROM n)::int + extract(year FROM n)::int) % array_length(tips, 1)];
END $$;

-- f_summary_data: extras_text passa a terminar com a dica (quando houver)
CREATE OR REPLACE FUNCTION f_summary_data(p_user bigint) RETURNS jsonb
LANGUAGE plpgsql STABLE SET search_path TO 'agente','public' AS $$
DECLARE
  v jsonb; c jsonb; pj text; t text := ''; x jsonb; NL text := chr(10); tip text;
BEGIN
  v := f_summary_data_base(p_user);
  c := COALESCE(v->'cards', '[]'::jsonb);
  FOR x IN SELECT * FROM jsonb_array_elements(c) LOOP
    t := t || '- Fatura ' || (x->>'name') || ' R$ ' || replace(to_char((x->>'amount')::numeric, 'FM999G990D00'), ',', '.') || ' vence ' || (x->>'due')
         || CASE WHEN (x->>'days')::int = 0 THEN ' (hoje)' WHEN (x->>'days')::int = 1 THEN ' (amanha)' ELSE '' END || NL;
  END LOOP;
  IF t <> '' THEN t := 'Cartoes:' || NL || t; END IF;
  pj := COALESCE(f_projects_summary(p_user)->>'text', '');
  IF pj <> '' THEN t := t || CASE WHEN t <> '' THEN NL ELSE '' END || pj; END IF;
  tip := f_tip(p_user);
  IF tip <> '' THEN t := rtrim(t, NL) || CASE WHEN rtrim(t, NL) <> '' THEN NL || NL ELSE '' END || tip; END IF;
  RETURN v || jsonb_build_object('extras_text', rtrim(t, NL));
END $$;
