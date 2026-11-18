# Vánoční přání – zprovoznění (asi 15 minut)

Složka obsahuje:

- `supabase.sql` – databáze a pravidla soukromí
- `web/` – samotná stránka (`index.html`, `config.js`)

## 1. Databáze (Supabase, zdarma)

1. Na supabase.com si založte účet a vytvořte nový projekt (region např. Frankfurt).
2. V levém menu **SQL Editor → New query**, vložte celý obsah `supabase.sql` a dejte **Run**.
3. **Authentication → Sign In / Providers** → zapněte **Allow anonymous sign-ins**.
   (Lidé se nepřihlašují e-mailem ani heslem, ale osobní pozvánkou – k tomu je tohle potřeba.)
4. **Project Settings → API (Data API / API Keys)**: zkopírujte **Project URL** a klíč **anon public**
   (v novějším rozhraní „publishable key“). Oba vložte do `web/config.js`.
   Klíč `service_role` / „secret“ nikam nedávejte.

## 2. Hosting (Netlify, zdarma)

1. Otevřete app.netlify.com/drop a přetáhněte tam složku `web`.
2. Dostanete adresu typu `https://nahodne-jmeno.netlify.app` – jméno lze změnit v nastavení webu.

Stejně dobře poslouží Vercel, Cloudflare Pages nebo jakýkoli webhosting – jsou to dva statické soubory.

## 3. První spuštění

1. Otevřete adresu webu. Objeví se „Založit rodinné Vánoce“ – zadejte své jméno. Tím se stáváte správcem.
   **Udělejte to hned po nahrání**, správcem se stane ten, kdo přijde první.
2. Na stránce **Rodina** si zkopírujte a uložte svou vlastní pozvánku (pro další zařízení).
3. Pro každého člena vytvořte pozvánku a pošlete mu ji zvlášť (SMS, WhatsApp, e-mail).
   Stačí na odkaz kliknout – žádná registrace ani heslo.

## Jak to funguje

- **Vlastní dopis**: každý člen má jeden. U svého dopisu nevidí, co je zabrané.
- **Dopis dítěte**: přidá ho rodič. Rodič (a správce) u něj vidí, co je zabrané, a může si sám vybírat.
- **Cizí dopisy**: je vidět jen to, co je ještě volné. Vybraný dárek ostatním zmizí. Jeden dárek si může vybrat jen jeden člověk.
- **Moje dárky**: soukromý seznam toho, co jsem si vybral(a).
- Odebrané přání se dárci neztratí – v „Moje dárky“ ho uvidí přeškrtnuté.

Tohle všechno hlídá databáze, ne jen stránka: informace „kdo co vybral“ se ze serveru vůbec neposílá.

## Dobré vědět

- **Pozvánka = klíč.** Kdo má odkaz, vstoupí jako daný člověk. Když se odkaz dostane jinam,
  dejte u člena „Nová pozvánka“ (stará přestane platit).
- **Ztratil jsem přístup jako správce**: v Supabase → SQL Editor spusťte
  `select name, invite_token from members;` a otevřete `https://VAŠE-ADRESA/#pozvanka=TOKEN`.
- **Správce databáze** (vy, přes Supabase) technicky vidí všechno včetně tabulky `claims`. Nedívejte se tam.
- Bezplatný projekt Supabase se po týdnu bez návštěvy uspí; probudíte ho tlačítkem v Supabase.
- **Nový ročník**: v SQL Editoru `truncate claims, wishes, letters cascade;` – členové a pozvánky zůstanou.
