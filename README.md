# Agente Pessoal no Telegram

Assistente pessoal que conversa pelo Telegram (texto e áudio) e ajuda no dia a dia com **lembretes, agenda, compromissos e estoque de itens de uso contínuo**. Uso inicial: duas pessoas (Adrian e a namorada), cada uma com seus próprios dados.

> Status (24/10/2026): **v1 construída e em teste.** Este README guarda o contexto das decisões de planejamento. A construção está em `db/` (schema e funções SQL) e `scripts/` (wizard de configuração); os workflows ficam no n8n: `Agente | Telegram`, `Agente | Disparador`, `Agente | Agenda Adrian` e `Agente | Agenda Maria Clara`. Política de privacidade: [PRIVACY.md](PRIVACY.md).
>
> Para refazer a instalação: aplique `db/001` a `db/005` no Postgres do agente, crie as credenciais no n8n com `scripts/setup-wizard.sh` e importe os workflows. Nenhum segredo fica neste repositório.

## Stack

| Peça | Escolha |
|---|---|
| Interface | Bot do Telegram (um bot, dois usuários autorizados por ID) |
| Orquestração | n8n já instalado no Easypanel da VPS |
| Banco | Postgres da VPS, schema e usuário próprios do agente |
| Cache / estado | Redis (estado de conversa, deduplicação, cache curto da agenda) |
| LLM | Gemini Flash (credencial "API GEMINI" já existente no n8n), saída JSON estruturada, temperatura baixa |
| Agenda | Google Calendar (fonte da verdade dos compromissos) |
| HTTPS | Fornecido pelo Easypanel (necessário para o webhook do Telegram) |

## Princípios

- **Tom e idioma:** português do Brasil, fuso `America/Sao_Paulo`. Horários gravados em UTC no banco e convertidos na exibição.
- **O modelo só interpreta.** O Gemini extrai intenção e campos em JSON. Quem executa (banco, Calendar, Telegram) são nós do n8n.
- **Nunca assumir horário.** Se o pedido não traz horário, o agente pergunta.
- **Autonomia controlada:** criar e consultar rodam direto, com aviso do que foi feito. Alterar e apagar sempre pedem confirmação. Mensagem para terceiros nunca sai sem confirmação explícita.

## Separação de dados entre usuários

Um bot só, um banco só, isolamento por `user_id`:

1. Toda mensagem do Telegram traz o `user_id` da conta de quem escreveu. Não vem do texto, então não dá para forjar.
2. O workflow rejeita IDs fora da lista permitida.
3. O `user_id` filtra todas as consultas ao banco e escolhe o ramo do Google Calendar, com a credencial da pessoa certa.
4. O webhook valida o `secret_token` do Telegram para recusar chamadas que não vieram do Telegram.

Existe também o conceito de **item compartilhado** ("lembra nós dois de..."), enviado às duas pessoas.

## Funções da v1 (MVP)

1. **Criar lembrete** por texto ou áudio. Sem horário, o agente pergunta.
2. **Avisos antes do compromisso.** Pedido explícito ("me lembre 1h antes") sempre vale. Sem pedido e sem padrão salvo, o agente oferece botões `[Não] [15 min] [1h] [1 dia]` e sugere a preferência "sempre me lembrar X antes". Pode haver vários avisos por compromisso.
3. **Criar compromisso** no Google Calendar (hora, duração, local).
4. **Consultar** hoje, amanhã e a semana.
5. **Concluir ou adiar lembrete.** Se não houver resposta, repete uma vez após 15 minutos, com `[Feito] [Adiar 1h] [Adiar amanhã]`. `[Adiar amanhã]` pergunta `[Mesmo horário] [Outro horário]`.
6. **Estoque de itens contínuos** (ex.: vitamina D), descrito abaixo.
7. **Resumo da manhã** às 7h30 (ajustável por pessoa) com agenda do dia e lembretes pendentes.
8. **Onboarding no `/start`** e comandos `/config` e `/ajuda`.

### Estoque de itens (vitamina D)

Dito em linguagem natural: *"tomo vitamina D todo dia, 1 por dia, a cartela tem 30, me avise quando estiver acabando"*. O Gemini extrai `item`, `quantidade`, `consumo_por_dia`, `data_de_inicio` e `avisar_com_X_dias`, e pergunta só o que faltar.

- Não há lembrete diário recorrente. O restante é **calculado**: `restante = quantidade − dias_desde_o_inicio × consumo`.
- O n8n agenda **um único aviso**, para a data em que faltarem 5 dias (padrão, alterável por item e no `/config`).
- Aviso: "sua vitamina D acaba em 5 dias, quer que eu lembre de comprar?" com `[Comprei] [Lembrar amanhã]`.
- Ao dizer "comprei", a contagem volta à quantidade original e o aviso é reagendado.
- A contagem começa hoje, salvo se a pessoa disser outra data. Aceita cartela em andamento ("tenho 18 na cartela") e ajustes ("pausei por 3 dias", "só tenho 12").

### Onboarding (`/start`)

1. Apresentação em duas linhas.
2. Confirmar o nome.
3. Escolher o horário do resumo da manhã (padrão 7h30).
4. Conectar o Google Calendar (ou pular e conectar depois).
5. Mini tutorial com cinco exemplos prontos: lembrete por áudio, compromisso, "o que tenho hoje", antecedência de aviso e **estoque de itens**.
6. Aviso de privacidade: os dados passam pelo Gemini.

## Arquitetura

- **Workflow principal** em fluxo fixo: Telegram → Gemini (JSON) → Switch por intenção → ação.
- **Dois sub-workflows pequenos**, "Agenda Adrian" e "Agenda Namorada", contendo apenas os nós do Google Calendar, cada um com sua credencial. O principal chama o certo pelo `user_id`.
- **Ramo "outros pedidos"** já previsto no Switch. Na v1 responde "ainda não sei fazer isso". Na v2 aponta para um sub-workflow com AI Agent.
- **Redis** (a revisar após testes): estado da conversa (ex.: aguardando o horário de um lembrete), deduplicação de mensagens do Telegram e cache de 10 minutos da agenda do dia, invalidado a cada escrita do agente. O resumo da semana consulta o Calendar na hora, sem cache longo, para não mostrar agenda desatualizada.
- **Banco** (schema próprio): `users`, `reminders`, avisos antecipados, `supplies` (estoque) e `events_cache`, todas com `user_id`.
- **Operação:** `pg_dump` diário do schema (retenção de 7 dias) e workflow de erro do n8n avisando por Telegram.

## Privacidade

- Agenda e dados de saúde (remédios) passam pelo Gemini. Adrian aceitou o uso, inclusive no plano gratuito. A namorada decide no onboarding.
- Áudios são baixados, enviados ao Gemini e apagados. Só o texto e a intenção ficam no banco.

## v2 (fora do MVP)

- **AI Agent** para pedidos abertos, como busca de **passagens aéreas** (fonte de dados a definir) e **"restaurantes mexicanos perto de mim"** via Google Places API: três melhores, ordenados por avaliação, distância e preferência, com links (formato a validar juntos). A localização vem do Telegram (botão de anexo) ou de um endereço salvo, sempre confirmando onde a pessoa está.
- Alterar e apagar compromissos pelo bot.
- Recorrência geral e tarefas.
- Foto/print (ex.: convite recebido).

## Estado do ambiente (verificado em 24/10/2026)

- n8n em `https://n8n-n8n.ymstas.easypanel.host`, com credenciais existentes: Google Calendar (OAuth), API GEMINI, dois Postgres ("Supabase Postgres" e "Postgres account") e tokens de projetos paralelos.
- Workflows existentes sem relação com este projeto: "FideliDellis — Expiração de Ciclos" e "Dieta — Estimativa Nutricional (IA)".
- Ainda não existe: bot no @BotFather, credencial do Telegram, credencial do Calendar da namorada, schema do agente, Redis.

## Pendências a verificar (fatos, não decisões)

- Qual dos dois Postgres é o da VPS e qual é o Supabase.
- Qual plano a chave Gemini usa.
- Se já existe Redis no Easypanel.
- Se o app OAuth do Google está em modo de teste (nesse caso o e-mail da namorada precisa entrar como usuário de teste).

## Próximos passos

1. Confirmar o entendimento e montar o plano de construção em fases.
2. Modelo de dados detalhado.
3. Prompt e schema JSON do Gemini.
4. Testes de aceitação.
5. Construção no n8n, por fases, testando junto.
