defmodule NunkiWeb.HelpLive do
  @moduledoc """
  The manual, at `/help`, in English and Dutch: what Nunki is, joining,
  what it says and when, the hall screen, voices per system, and what to
  do when it is quiet when it should not be. Text only; nothing is read
  from the program, so it stays right when the program is the thing that
  is wrong.
  """
  use NunkiWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Nunki.Updates.subscribe()
    {:ok, assign(socket, page_title: gettext("Help"), update: Nunki.Updates.notice())}
  end

  # A newer version heard of, or put off: the banner follows.
  @impl true
  def handle_info(:update_changed, socket),
    do: {:noreply, assign(socket, update: Nunki.Updates.notice())}

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(%{locale: "nl"} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:help} update={@update}>
      <article id="manual" class="manual">
        <h1>Nunki, de omroeper van de zaal</h1>

        <section id="manual-what">
          <h2>Wat Nunki doet</h2>

          <p>
            Nunki leest de indeling voor zodra die in OpenPairings gepubliceerd is ("Bord 1: ... tegen ..."), en telt af naar het begin van de ronde: tien minuten, vijf minuten, één minuut, en "Ronde 3 begint nu". Het draait op een computer in de zaal met luidsprekers eraan, en spreekt met de stem van het besturingssysteem.
          </p>

          <p>
            Wat er omgeroepen wordt, beslis je in OpenPairings. Deze pagina is er om Nunki aan een toernooi te koppelen, de stem te kiezen en in te grijpen: nu voorlezen, stoppen, zelf een aftelling starten.
          </p>
        </section>

        <section id="manual-join">
          <h2>Een toernooi koppelen</h2>

          <ol>
            <li>
              In OpenPairings: de instellingen van het toernooi → Omroeper → "Omroeper toevoegen".
            </li>

            <li>
              Kopieer de link en plak hem op deze pagina in "Bij een toernooi aansluiten". Druk op Aansluiten. Staat OpenPairings op een ander toestel? Scan de QR-code met Manubrium op je telefoon: die herkent de link als een link voor Nunki en laat je hem kopiëren of delen naar deze pc.
            </li>

            <li>Het toernooi staat in de lijst. Een groene stip: de verbinding staat.</li>
          </ol>

          <p>
            De link werkt één keer en vijftien minuten lang. Verlopen? Maak een nieuwe. Een link voor een printstation (Polis) of voor de telefoon-app (Manubrium) werkt hier niet, en wordt geweigerd voor hij opgebruikt raakt. Een toernooi dat al gekoppeld is, blijft gekoppeld: de link is alleen nodig om aan te sluiten.
          </p>

          <p id="manual-room-nl">
            <em>Geavanceerd.</em>
            Elk toernooi heeft voor deze omroeper een naam en een ruimte (handig als de zaal meer dan één ruimte heeft). OpenPairings bewaart ze en is de baas: wijzig ze daar bij Instellingen → Omroeper, of hier, in de rij van het toernooi, zolang de verbinding aanstaat. Wat je hier invult is een verzoek; je ziet pas de nieuwe waarde als de server hem terugstuurt. Wie het laatst wijzigt, wint.
          </p>

          <p>
            De ruimte kies je uit de ruimtes van het toernooi (die maak je in OpenPairings bij Instellingen → Ruimtes). Een omroeper in een ruimte krijgt alleen de borden van die ruimte te horen; zonder ruimte krijgt hij ze allemaal. Een ruimte die het toernooi niet heeft, wordt geweigerd.
          </p>
        </section>

        <section id="manual-speech">
          <h2>Wat Nunki zegt, en wanneer</h2>

          <ul>
            <li>
              Een nieuwe ronde gepubliceerd: de indeling wordt voorgelezen, als "Lees de indeling voor als ze gepubliceerd wordt" aan staat. Wordt een ronde die al voorgelezen is daarna nog aangepast, dan leest Nunki ze niet vanzelf opnieuw voor; druk dan op "Nu voorlezen".
            </li>

            <li>
              Een aftelling, uit OpenPairings of van hier: op tien, vijf en één minuut, en op nul. Alleen de momenten die nog komen; wie op vijf minuten start, hoort geen tien.
            </li>

            <li>"Stop" zwijgt meteen en vergeet wat nog moest komen.</li>
          </ul>

          <p>
            De taal volgt het toernooi (de taal van het OpenPairings-account), tenzij je bij "Taal van de omroep" Engels of Nederlands kiest.
          </p>
        </section>

        <section id="manual-hall">
          <h2>Het zaalscherm</h2>

          <p>
            <a href="/hall">/hall</a>
            is een donker scherm voor een beamer of een tv: tijdens een aftelling de minuten in grote cijfers, anders de laatste indeling, en onderaan de zin die Nunki uitspreekt. De knop rechtsboven zet het scherm op volledig scherm. Met meer toernooien kies je er een met de knop "Zaalscherm" bij dat toernooi.
          </p>

          <p>
            Het scherm is een extraatje. Nunki spreekt ook als het niet openstaat.
          </p>
        </section>

        <section id="manual-voices">
          <h2>Stemmen (geavanceerd)</h2>

          <ul>
            <li>
              Windows: Engels is er altijd. Voor Nederlands voeg je de taal toe onder Instellingen, Tijd en taal, Spraak, en start je Nunki opnieuw.
            </li>

            <li>
              macOS: download een Nederlandse stem onder Systeeminstellingen, Toegankelijkheid, Gesproken materiaal.
            </li>

            <li>
              Linux: installeer espeak-ng. Het klinkt als een robot, maar wel een die op tijd is.
            </li>
          </ul>

          <p>
            Kies per taal een stem en druk op "Test de stem" om te horen hoe het klinkt in de zaal. Deze keuzes zie je pas als "Geavanceerde functies tonen" aanstaat; zonder gekozen stem neemt Nunki die van het systeem.
          </p>
        </section>

        <section id="manual-update">
          <h2>Nieuwe versies (instellingen geavanceerd)</h2>

          <p>
            Nunki kijkt elk half uur of er een nieuwe versie is, en zegt het dan bovenaan de bedieningspagina en hier. Installeren doe je zelf: Nunki is dan ongeveer een minuut stil. Loopt er een aftelling of wordt er voorgelezen, dan vraagt Nunki eerst; "Toch installeren" is het tweede ja. Het zaalscherm toont nooit dat er een update is. Wil je er niets van horen, zet dan "Zoeken naar nieuwe versies" uit.
          </p>

          <p>
            De installatie voor Windows en die voor Linux (met install.sh) werken zichzelf bij. Een draagbare kopie en de Mac-app vervang je met de hand. Een geïnstalleerde Windows-kopie kan ook met Windows mee starten; dat staat uit tot je het aanzet.
          </p>
        </section>

        <section id="manual-advanced">
          <h2>Geavanceerde functies</h2>

          <p>
            De bedieningspagina is standaard klein: de omroep zelf, de lijst met toernooien, aansluiten, "Nu voorlezen", een aftelling, en de taal en "Lees de indeling voor als ze gepubliceerd wordt". Zet je onderaan "Geavanceerde functies tonen" aan, dan verschijnen ook:
          </p>

          <ul>
            <li>
              de keuze van de Engelse en Nederlandse stem, "Test de stem" en "Zoek opnieuw naar stemmen";
            </li>

            <li>naam en ruimte per toernooi;</li>

            <li>
              het blok "Dit apparaat": de naam van het apparaat, zoeken naar nieuwe versies en met Windows starten.
            </li>
          </ul>

          <p>
            Uit is de standaard. Niets verdwijnt echt: een stem die je gekozen hebt blijft gebruikt worden als de keuze verborgen is. Een Nunki die al eigen waarden had (een gekozen stem, een ruimte, een eigen apparaatnaam, updates uit) start met de schakelaar aan, zodat niemand iets kwijtraakt. Is er geen spraakmotor, dan meldt de pagina dat altijd.
          </p>
        </section>

        <section id="manual-data">
          <h2>Waar Nunki bewaart wat het weet</h2>

          <p>
            Eén bestand, <span class="mono">state.json</span>, in een map die nooit binnen het programma zelf ligt, zodat een update of het verwijderen van Nunki er niet aan komt: op Windows <span class="mono">%LOCALAPPDATA%\NunkiData</span>, op een Mac <span class="mono">~/Library/Application Support/NunkiData</span>, op Linux met install.sh <span class="mono">/var/lib/nunki</span>, anders <span class="mono">~/.nunki</span>. De omgevingsvariabele
            <span class="mono">NUNKI_DATA</span>
            kiest een andere.
          </p>

          <p>
            Daarin staan de toernooien met hun sleutels en de instellingen. Geef dat bestand aan niemand: met de sleutels kan een ander zich als deze omroeper aanmelden.
          </p>
        </section>

        <section id="manual-trouble">
          <h2>Als het stil blijft</h2>

          <ul>
            <li>
              Rode stip bij het toernooi: de reden staat ernaast. Nunki probeert het zelf opnieuw.
            </li>

            <li>
              "Geen stem": zie hierboven. Zonder stem kiest het systeem er zelf een, en dat is soms Engels dat Nederlands leest.
            </li>

            <li>
              Linux als dienst: zie de README over geluid. Start Nunki desnoods als de gebruiker die ingelogd is, met nunki.sh.
            </li>
          </ul>
        </section>
      </article>
    </Layouts.app>
    """
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} locale={@locale} page={:help} update={@update}>
      <article id="manual" class="manual">
        <h1>Nunki, the hall announcer</h1>

        <section id="manual-what">
          <h2>What Nunki does</h2>

          <p>
            Nunki reads the pairings aloud as soon as they are published in OpenPairings ("Board 1: ... against ..."), and counts down to the start of the round: ten minutes, five minutes, one minute, and "Round 3 starts now". It runs on a computer in the hall with speakers attached, and speaks with the operating system's own voice.
          </p>

          <p>
            What is announced is decided in OpenPairings. This page is for joining Nunki to a tournament, choosing the voice and stepping in: read now, stop, start a countdown of your own.
          </p>
        </section>

        <section id="manual-join">
          <h2>Joining a tournament</h2>

          <ol>
            <li>
              In OpenPairings: the tournament's Settings → Hall announcer → "Add an announcer".
            </li>

            <li>
              Copy the link and paste it into "Join a tournament" on this page. Press Join. OpenPairings open on another device? Scan the QR code with Manubrium on your phone: it recognises the link as one for Nunki and lets you copy or share it to this PC.
            </li>

            <li>The tournament is in the list. A green dot: the line is up.</li>
          </ol>

          <p>
            The link works once, for fifteen minutes. Expired? Make a new one. A print station's link (Polis) or the phone app's (Manubrium) does not work here, and is refused before it gets used up. A tournament already joined stays joined: the link is only needed to join.
          </p>

          <p id="manual-room-en">
            <em>Advanced.</em>
            Each tournament gives this announcer a name and a room (handy when the hall has more than one room). OpenPairings keeps them and has the final say: change them there under Settings → Hall announcer, or here, in the tournament's row, while the line is up. What you type here is a request; you see the new value once the server sends it back. Whoever changes it last wins.
          </p>

          <p>
            The room is chosen from the tournament's rooms (made in OpenPairings under Settings → Rooms). An announcer in a room is read only the boards of that room; with no room it gets them all. A room the tournament does not have is refused.
          </p>
        </section>

        <section id="manual-speech">
          <h2>What Nunki says, and when</h2>

          <ul>
            <li>
              A new round published: the pairings are read, if "Read the pairings when they are published" is on. A round that was already read and is corrected afterwards is not read again by itself; press "Read now" for that.
            </li>

            <li>
              A countdown, from OpenPairings or from here: at ten, five and one minute, and at zero. Only the moments still ahead; start one at five minutes and there is no "ten".
            </li>

            <li>"Stop" is quiet at once and forgets what was still to come.</li>
          </ul>

          <p>
            The language follows the tournament (the OpenPairings account's language), unless you pick English or Nederlands under "Language of the announcements".
          </p>
        </section>

        <section id="manual-hall">
          <h2>The hall screen</h2>

          <p>
            <a href="/hall">/hall</a>
            is a dark screen for a projector or a TV: during a countdown the minutes in big digits, otherwise the latest pairings, and at the bottom the line Nunki is saying. The button at the top right makes it full screen. With more than one tournament, pick one with the "Hall screen" button beside it.
          </p>

          <p>
            The screen is an extra. Nunki speaks whether it is open or not.
          </p>
        </section>

        <section id="manual-voices">
          <h2>Voices (advanced)</h2>

          <ul>
            <li>
              Windows: English is always there. For Dutch, add the language under Settings, Time & language, Speech, and restart Nunki.
            </li>

            <li>
              macOS: download a Dutch voice under System Settings, Accessibility, Spoken Content.
            </li>

            <li>Linux: install espeak-ng. It sounds like a robot, but a punctual one.</li>
          </ul>

          <p>
            Choose a voice per language and press "Test voice" to hear how it sounds in the hall. These choices only show when "Show advanced features" is on; with no voice chosen, Nunki uses the system's own.
          </p>
        </section>

        <section id="manual-update">
          <h2>New versions (settings are advanced)</h2>

          <p>
            Nunki looks for a new version every half hour and says so at the top of the control page and here. Installing is yours to start: Nunki is quiet for about a minute. When a countdown runs or something is being read, Nunki asks first; "Install anyway" is the second yes. The hall screen never shows that there is an update. To hear nothing of it, switch off "Look for new versions".
          </p>

          <p>
            The Windows installation and the Linux one (with install.sh) update themselves. A portable copy and the Mac app are replaced by hand. An installed Windows copy can also start with Windows; that is off until you switch it on.
          </p>
        </section>

        <section id="manual-advanced">
          <h2>Advanced features</h2>

          <p>
            The control page is small by default: the announcer itself, the list of tournaments, joining, "Read now", a countdown, and the language and "Read the pairings when they are published". Switch on "Show advanced features" at the bottom and these appear as well:
          </p>

          <ul>
            <li>the choice of English and Dutch voice, "Test voice" and "Look for voices again";</li>

            <li>name and room per tournament;</li>

            <li>
              the "This device" block: the device's name, looking for new versions and starting with Windows.
            </li>
          </ul>

          <p>
            Off is the default. Nothing really goes away: a voice you chose keeps being used while its choice is hidden. A Nunki that already had values of its own (a chosen voice, a room, its own device name, updates off) starts with the switch on, so nobody loses what they use. If there is no speech engine, the page says so either way.
          </p>
        </section>

        <section id="manual-data">
          <h2>Where Nunki keeps what it knows</h2>

          <p>
            One file, <span class="mono">state.json</span>, in a folder that is never inside the program itself, so that an update or removing Nunki does not touch it: on Windows <span class="mono">%LOCALAPPDATA%\NunkiData</span>, on a Mac <span class="mono">~/Library/Application Support/NunkiData</span>, on Linux with install.sh <span class="mono">/var/lib/nunki</span>, otherwise <span class="mono">~/.nunki</span>. The environment variable
            <span class="mono">NUNKI_DATA</span>
            picks another.
          </p>

          <p>
            In it are the tournaments with their keys, and the settings. Give that file to nobody: with the keys, someone else can sign in as this announcer.
          </p>
        </section>

        <section id="manual-trouble">
          <h2>When it stays quiet</h2>

          <ul>
            <li>
              A red dot by the tournament: the reason is beside it. Nunki tries again by itself.
            </li>

            <li>
              "No voice": see above. Without one the system picks its own, and that is sometimes English reading Dutch.
            </li>

            <li>
              Linux as a service: see the README on sound. If need be, run Nunki as the logged-in user, with nunki.sh.
            </li>
          </ul>
        </section>
      </article>
    </Layouts.app>
    """
  end
end
