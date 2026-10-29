# Agente Pessoal no Telegram

Assistente pessoal que conversa pelo Telegram (texto e áudio) e ajuda no dia a dia com **lembretes, agenda, compromissos e estoque de itens de uso contínuo**. Uso inicial: duas pessoas (Adrian e a namorada), cada uma com seus próprios dados.

> Status (26/10/2026): **fases 2 e 3 construídas** (finanças completas com planejamento e cartões, resumos, gestão de agenda, lembretes recorrentes, contatos e convites com Meet). IA em OpenAI. Este README guarda o contexto das decisões de planejamento. A construção está em `db/` (schema e funções SQL) e `scripts/` (wizard de configuração); os workflows ficam no n8n: `Agente | Telegram`, `Agente | Disparador`, `Agente | Agenda Adrian` e `Agente | Agenda Maria Clara`. Política de privacidade: [PRIVACY.md](PRIVACY.md).
>
> Para refazer a instalação: aplique `db/001` a `db/014` no Postgres do agente, crie as credenciais no n8n com `scripts/setup-wizard.sh` e importe os workflows. Nenhum segredo fica neste repositório.

## Stack

| Peça | Escolha |
|---|---|
| Interface | Bot do Telegram (um bot, dois usuários autorizados por ID) |
| Orquestração | n8n já instalado no Easypanel da VPS |
| Banco | Postgres da VPS, schema e usuário próprios do agente |
| Cache / estado | Redis (estado de conversa, deduplicação, cache curto da agenda) |
| LLM | OpenAI (nó nativo do n8n, credencial "OpenAI account"): `gpt-6-luna` para interpretar texto e foto com JSON de schema estrito e `GPT` de transcrição para áudio. O modelo vem da chave Redis `agente:cfg:model`, então dá para trocar sem republicar (`set agente:cfg:model gpt-6.1-sol`) |
| Agenda | Google Calendar (fonte da verdade dos compromissos) |
| HTTPS | Fornecido pelo Easypanel (necessário para o webhook do Telegram) |

## Princípios

- **Tom e idioma:** português do Brasil, fuso `America/Sao_Paulo`. Horários gravados em UTC no banco e convertidos na exibição.
- **O modelo só interpreta.** A IA (OpenAI) extrai intenção e campos em JSON de schema estrito. Quem executa (banco, Calendar, Telegram) são nós do n8n.
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

Dito em linguagem natural: *"tomo vitamina D todo dia, 1 por dia, a cartela tem 30, me avise quando estiver acabando"*. A IA extrai `item`, `quantidade`, `consumo_por_dia`, `data_de_inicio` e `avisar_com_X_dias`, e pergunta só o que faltar.

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
6. Aviso de privacidade: os dados passam pela OpenAI.

## Arquitetura

- **Workflow principal** em fluxo fixo: Telegram → (áudio: transcrição) → OpenAI (JSON) → Switch por intenção → ação.
- **Dois sub-workflows pequenos**, "Agenda Adrian" e "Agenda Namorada", contendo apenas os nós do Google Calendar, cada um com sua credencial. O principal chama o certo pelo `user_id`.
- **Ramo "outros pedidos"** já previsto no Switch. Na v1 responde "ainda não sei fazer isso". Na v2 aponta para um sub-workflow com AI Agent.
- **Redis** (a revisar após testes): estado da conversa (ex.: aguardando o horário de um lembrete), deduplicação de mensagens do Telegram e cache de 10 minutos da agenda do dia, invalidado a cada escrita do agente. O resumo da semana consulta o Calendar na hora, sem cache longo, para não mostrar agenda desatualizada.
- **Banco** (schema próprio): `users`, `reminders`, avisos antecipados, `supplies` (estoque) e `events_cache`, todas com `user_id`.
- **Operação:** `pg_dump` diário do schema (retenção de 7 dias) e workflow de erro do n8n avisando por Telegram.

## Finanças (v1.1)

Cada pessoa tem as próprias finanças (nada é compartilhado). Tudo é dito em linguagem natural, por texto, áudio ou foto de recibo; a lógica vive no Postgres (`db/008_financas.sql`, função `agente.f_fin`).

- **Lançamentos:** gasto ou receita, com forma de pagamento (pix, débito, crédito, dinheiro, boleto). Texto e áudio claros gravam direto com botão **Desfazer**; foto de recibo mostra o que leu e pede **Confirmar**. Nunca grava valor que a IA não leu com certeza.
- **Categorias:** padrão (Alimentação, Mercado, Transporte, Moradia, Saúde, Lazer, Educação, Assinaturas, Compras, Outros; receitas: Recebimentos, Salário) mais as que a pessoa cria, com palavras-chave. A categoria vem do que a pessoa disse, do histórico da mesma descrição, do palpite da IA ou das palavras-chave.
- **Contas a pagar e recorrentes:** "aluguel 1500 todo dia 5" cria uma conta pendente e um lembrete no dia (Feito dá baixa); "já paguei" também. Parcelas ("tênis 600 em 3x") entram mês a mês.
- **Orçamento por categoria** com aviso a 80% e a 100%, sugestão pela média dos 2 meses anteriores, e **dia de fechamento** do mês financeiro (padrão 5, mudável).
- **Consultas:** resumo do mês, comparação com o mês anterior, maiores despesas, gastos por dia, "quem me deve".
- **Fora desta versão:** importação de extrato, Open Finance, relatórios em PDF/Excel.

## Planejamento financeiro (fase 2)

`db/011_planejamento.sql`. Tudo editável por frase.

- **Limite geral do mês** ("quero gastar no máximo 3000"): conta só gastos pagos, avisa a 80% e a 100% (junto com o aviso da categoria), mostra quanto ainda pode gastar por dia. "Muda para 3500", "tira o limite".
- **Metas de economia** ("juntar 800 até dezembro pro presente"): progresso automático (receitas pagas menos gastos desde a criação, dividido entre as metas automáticas) mais registro manual ("guardei 100", "tirei 50"). "Essa meta é só manual" liga o modo manual. Apagar pede confirmação.
- **Meu planejamento**: renda (prevista com "minha renda é 5000" ou as receitas recebidas) menos gasto, menos já comprometido (contas a pagar e parcelas), menos o que as metas pedem no mês.
- **Preferências por frase**: apelido, parar de usar emoji, fuso horário, ligar e desligar os resumos da manhã e do fim do dia, horário do resumo, expediente.
- **Cartões e faturas** (`db/013_extras.sql`): nome, fechamento, vencimento e limite; lançamento "no cartão do Itaú"; fatura aberta e fechada, limite disponível; aviso antes do vencimento. Consultas por categoria e mês, por forma de pagamento, "quanto sobrou para fechar o mês" e "quanto já comprometi de novembro".

## Agenda (fase 2, `db/012_agenda.sql`)

- Mover e cancelar compromissos com **Confirmar**; vários candidatos viram até 3 botões numerados; evento com convidados avisa o Google só após a confirmação; evento recorrente pergunta "só este" ou "a série".
- **Conflito de horário** ao criar ou mover, com "Marcar mesmo assim" e "Outro horário".
- **Horário livre** dentro do expediente (08:00 a 19:00, blocos de 30 min ou mais).
- **Compromissos recorrentes** (diário, semanal, mensal). O aviso "me lembre antes" cobre a próxima ocorrência. Um lembrete pode ser **ligado ao compromisso e à pessoa** ("levar uma calça pra Maria Luísa na celebração").
- **Convites recebidos**: o bot avisa e oferece Aceitar ou Recusar (verificado com um convite real).
- Transformar um lembrete em compromisso; link da agenda.
- **Lembrete recorrente genérico** (todo dia, toda sexta, todo dia 5) e "para de me lembrar".

## Contatos, grupos e convites (fase 3, `db/014_contatos_convites.sql`)

"Salva o e-mail da Cláudia", grupos ("cria o grupo time com Douglas e Bia"), "chama o Douglas e a Bia pra sexta 16h" e "marca 30 min com a contadora e manda o link". O bot **sempre confirma** antes de mandar convite e nunca inventa e-mail: nome sem cadastro vira um pedido do e-mail.

## Documentos, listas, notas e projetos (fase 4, `db/015` a `db/018`)

- **Documentos** (`015_documentos.sql`): foto, PDF, vídeo ou qualquer arquivo até 50 MB. O banco guarda só o `file_id` do Telegram e metadados (título, pasta, tipo, tamanho, vencimento), nunca o conteúdo. "Guarda essa aqui na pasta Casa", "acha a apólice", "me manda tudo da reforma" (reenvia pelo `file_id`), "me avisa antes do alvará vencer" (lembrete de vencimento). Apagar pede confirmação por botão.
- **Listas e notas** (`016_listas_notas.sql`): "lista de mercado: arroz, café", "marca o arroz", "limpa a lista", "anota a ideia da assinatura anual", "o que eu tinha anotado sobre a expansão?". Apagar lista ou nota pede confirmação.
- **Projetos** (`017_projetos.sql`): projeto com prazo, tarefas, urgente, concluir e atrasadas. Uma tarefa entra direto; várias, ou "quebra o projeto em tarefas", pedem confirmação por botão.
- **Resumos** (`018_resumo_fase4.sql`): `f_summary_data` passa a devolver `extras_text` com tarefas de projeto atrasadas, projetos com prazo nos próximos 7 dias e faturas de cartão a vencer; o texto entra no fim do resumo da manhã e do fim do dia.
- Roteamento de botões em `agente.f_callback` (prefixos `ag`, `ct`, `ex`, `dc`, `ls`, `pj`).
- As regras estáticas do prompt ficam no Redis (chave `agente:cfg:rules`), lidas pelo nó `Ler regras`; sem a chave o bot fica degradado.
- Limite conhecido: "anota: ligar pro eletricista" vira tarefa do Google Tasks (é um afazer); para guardar um texto livre, peça "anota a ideia..." ou "guarda uma nota".

## Resumos (v1.2)

- **Manhã** (horário da pessoa, padrão 07:30): Compromissos, Tarefas e Lembretes sempre aparecem (com "nenhum" quando vazios). Contas a pagar (atrasadas, de hoje e dos próximos 7 dias), Dinheiro (gasto de ontem e categorias a 80% ou mais do orçamento) e Hora de comprar só aparecem se houver algo.
- **Fim do dia** (20:00 por padrão, `users.evening_enabled` liga e desliga): pendências de hoje (tarefas, lembretes, contas) ou "tudo em dia", e o que vem amanhã.
- Dados em `agente.f_summary_data`; quem recebe, em `agente.f_summary_candidates`; texto montado no workflow `Agente | Disparador`.

## Privacidade

- Agenda e dados de saúde (remédios) passam pela OpenAI, com armazenamento de respostas desativado. Os dois usuários estão cientes.
- Áudios são baixados, enviados à OpenAI para transcrição e apagados. Só o texto e a intenção ficam no banco.

## v2 (fora do MVP)

- **AI Agent** para pedidos abertos, como busca de **passagens aéreas** (fonte de dados a definir) e **"restaurantes mexicanos perto de mim"** via Google Places API: três melhores, ordenados por avaliação, distância e preferência, com links (formato a validar juntos). A localização vem do Telegram (botão de anexo) ou de um endereço salvo, sempre confirmando onde a pessoa está.
- Fase 5: pesquisa com fonte e limite diário de uso.

## Estado do ambiente (verificado em 24/10/2026)

- n8n em `https://n8n-n8n.ymstas.easypanel.host`, com credenciais existentes: Google Calendar (OAuth), API GEMINI, dois Postgres ("Supabase Postgres" e "Postgres account") e tokens de projetos paralelos.
- Workflows existentes sem relação com este projeto: "FideliDellis — Expiração de Ciclos" e "Dieta — Estimativa Nutricional (IA)".
- Ainda não existe: bot no @BotFather, credencial do Telegram, credencial do Calendar da namorada, schema do agente, Redis.

## Pendências a verificar (fatos, não decisões)

- Qual dos dois Postgres é o da VPS e qual é o Supabase.
- Se já existe Redis no Easypanel.
- Se o app OAuth do Google está em modo de teste (nesse caso o e-mail da namorada precisa entrar como usuário de teste).

## Próximos passos

1. Confirmar o entendimento e montar o plano de construção em fases.
2. Modelo de dados detalhado.
3. Prompt e schema JSON da IA.
4. Testes de aceitação.
5. Construção no n8n, por fases, testando junto.
