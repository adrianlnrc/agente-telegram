# Política de Privacidade — Agente Pessoal (MeuAssessor)

Última atualização: 24/10/2026

O **Agente Pessoal** (identificado no Google como *MeuAssessor*) é um assistente de uso particular, criado e operado por Adrian Alencar, usado por um grupo restrito de pessoas autorizadas (duas, no momento). Ele não é um serviço aberto ao público, e não há cadastro de terceiros.

Página inicial do projeto: https://github.com/adrianlnrc/agente-telegram

## Quais dados são tratados

- **Mensagens e áudios do Telegram** enviados ao assistente. Os áudios são baixados, enviados para transcrição e interpretação e **apagados em seguida**; só o texto interpretado e a ação resultante são guardados.
- **Lembretes, avisos e itens de estoque** que a pessoa pede ao assistente (por exemplo, título, data e hora, antecedência do aviso).
- **Preferências** da pessoa (como o horário do resumo diário).
- **Dados do Google Calendar**, quando a pessoa autoriza a conexão: o assistente **lê** os eventos do dia ou do período pedido e **cria** eventos que a pessoa solicitou. Ele não apaga nem altera eventos existentes e não compartilha a agenda com terceiros.

## Como os dados são usados

Somente para executar o que a pessoa pediu: criar lembretes e eventos, avisar nos horários combinados, montar o resumo da manhã e responder consultas sobre a agenda e o estoque.

## Com quem os dados são compartilhados

- **Google (Gemini):** o conteúdo das mensagens é enviado à API do Gemini para ser interpretado. 
- **Google (Calendar):** para ler e criar eventos, conforme a autorização concedida.
- **Telegram:** para receber e enviar as mensagens.

Não vendemos nem cedemos dados a terceiros para publicidade ou outros fins. O uso das informações obtidas das APIs do Google segue a [Política de Dados de Usuário dos Serviços de API do Google](https://developers.google.com/terms/api-services-user-data-policy), incluindo os requisitos de Uso Limitado.

## Onde os dados ficam

Em um servidor privado (VPS) controlado pelo responsável, em banco de dados com acesso restrito. As credenciais de acesso ao Google ficam armazenadas de forma protegida na ferramenta de automação usada pelo agente (n8n).

## Retenção e exclusão

Os dados ficam guardados enquanto a pessoa usar o assistente. Ela pode pedir a exclusão dos seus dados, ou revogar o acesso ao Google Calendar a qualquer momento em https://myaccount.google.com/permissions. Para pedir exclusão ou tirar dúvidas, escreva para **spottyadrian@gmail.com**.

## Alterações

Esta política pode ser atualizada. A data da última atualização fica no topo deste documento.
