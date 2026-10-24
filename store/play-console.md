# Play Console answers for AgentEmpire

Field-by-field answers for setting up AgentEmpire (`ai.zeenie.agentempire`) in Google Play
Console for the closed test. Play's wording changes from time to time; where a question reads
differently, the facts below decide the answer.

**What the answers rest on.** Release 1 is the offline town: gather food and wood, build
cottages, farms and storehouses, train townsfolk, save the town. There is no Town Hall on the
phone, so there are no AI agents, no network access, no ads, no analytics and no accounts. The
app is free, has no purchases and is aimed at ages 13 and up. The town is saved only in the
app's private storage. These answers stay true only while the Android preset keeps:

- no Internet permission, and no permission that reaches the user's data (stream A's
  `aapt2 dump badging` check);
- no `com.google.android.gms.permission.AD_ID` permission and no ad, analytics or crash SDK;
- user data backup off (`user_data_backup/allow=false`, Godot's default);
- the town and settings in `user://` only.

**From Play Console** (Developer account page), used here and in `docs/privacy.md`: the public
developer email `flame2talon@gmail.com` and the developer name `flame2talon`, shown on the
listing (Play wants the privacy policy to name it).

## Create app

| Field | Answer |
|---|---|
| App name | AgentEmpire: Town Builder (the store title, 25 of 30; the phone's launcher shows AgentEmpire) |
| Default language | English (United States) - en-US |
| App or game | Game |
| Free or paid | Free (a free app can never become paid; there are no purchases, so this is fine) |
| Declarations | Tick both: the Developer Program Policies, and US export laws |

## App content

### Privacy policy

`https://zeenie-ai.github.io/AgentEmpire/privacy/`

It must answer 200 before the app is sent for review: the owner pushes `docs/privacy.md` to
master and turns on GitHub Pages (master, /docs), with both markers filled in.

### Ads

**No, my app does not contain ads.**

### App access

**All functionality in my app is available without any access restrictions.** There is no
sign-in, membership, code or location requirement; the game starts on the town.

### Content rating

| Step | Answer |
|---|---|
| Email address (for IARC's certificate) | flame2talon@gmail.com |
| Category | Game |
| Violence | No. Townsfolk gather, farm and build; there is no combat, no enemy, and no one is hurt |
| Fear | No. Nothing frightening or horror-themed |
| Sexuality and nudity | No |
| Gambling | No: no real or simulated gambling, no loot boxes or random rewards |
| Language | No: no profanity or crude humour |
| Controlled substances | No: no drugs, alcohol or tobacco |
| Users interact or exchange content (chat, sharing, user-generated content) | No: single player and offline |
| Shares the user's current physical location with other users | No |
| Allows users to purchase digital goods | No |
| Unrestricted internet access (web browser, search engine) | No |
| Any other question (for example hate symbols, crypto or NFTs) | No |

Expected result: the youngest rating everywhere (for example PEGI 3, ESRB Everyone). If the
summary shows anything older, recheck the answers before submitting.

### Target audience and content

| Step | Answer |
|---|---|
| Target age groups | Ages 13-15, Ages 16-17, Ages 18 and over. Not 5 and under, 6-8 or 9-12 |
| Could the app or its store listing appeal to children (if asked) | No. It is a strategy and town-management game; the listing has no child-directed wording, characters, prizes or offers |
| Ads (asked only for apps with ads) | Not asked: no ads |

Google reviews this declaration against the listing. The KayKit art is bright and low-poly, so a
reviewer could still judge that the game appeals to children; if so, Play asks for the Families
policy, which the app already meets on the data side (no ads, nothing collected). Play also
notes that 13-15 can count as children in some countries; with nothing collected, that changes
no answer here.

### News apps

**No**, it is not a news app.

### COVID-19 contact tracing and status apps

**My app is not a publicly available COVID-19 contact tracing or status app.**

### Data safety

| Question | Answer |
|---|---|
| Does your app collect or share any of the required user data types? | **No** |
| Is all of the user data collected by your app encrypted in transit? | Not asked after No |
| Do you provide a way for users to request that their data is deleted? | Not asked after No; there is nothing to delete outside the device, and uninstalling removes the saves |
| Account creation (if asked) | The app has no accounts |
| Independent security review (optional badge) | Leave empty |

Play counts data as collected when the app sends it off the device. The app cannot send
anything: it has no Internet permission and no SDK that collects data, and the town and the
settings stay in its private storage. The listing then shows "No data collected" and "No data
shared with third parties".

### Government apps

**No**, it is not developed by or for a government.

### Financial features

**My app doesn't provide any financial features.**

### Health

**My app does not have any health features.**

### Advertising ID

**No**, the app does not use the advertising ID. The manifest must not contain
`com.google.android.gms.permission.AD_ID`; check it in stream A's badging output.

### Other declarations

- Sensitive permission declarations (photos and videos, foreground services, full-screen
  intents, exact alarms, accessibility, VPN and others) appear only when the manifest asks for
  those permissions. Release 1 asks for none of them, so none should appear.
- If Play asks whether the app uses generative AI: **No**. The Android app has no AI features;
  the AI agents exist only in the PC version.

## Store settings

| Field | Answer |
|---|---|
| App category | Game > Strategy |
| Tags (up to 5) | Pick from Play's list, in this order: Real-time strategy; City building (or Building); Medieval; Single player; Offline. If one is missing, use Fantasy, Stylized, Casual or Management |
| Store listing contact email | flame2talon@gmail.com (public) |
| Phone | Leave empty |
| Website | `https://github.com/zeenie-ai/AgentEmpire` |
| External marketing | Leave on (the default) |

## Main store listing

| Field | Where |
|---|---|
| App name, short description, full description | `store/listing.md` |
| App icon (512 x 512, 32-bit PNG) | `store/graphics/icon-512.png` |
| Feature graphic (1024 x 500, 24-bit PNG) | `store/graphics/feature-1024x500.png` |
| Phone screenshots | 7 at 1920 x 1080, in this order: `out/store/shots/1920x1080-1-town.png` to `-7-help.png` |
| 7-inch tablet screenshots | 3 at 1920 x 1200: `out/store/shots/1920x1200-1-town.png` to `-3-build.png` |
| 10-inch tablet screenshots | 4 at 2560 x 1440: `out/store/shots/2560x1440-1-keep.png` to `-4-build.png` |
| Video | None |

`client/tools/store_art.gd` renders the icon, the feature graphic and the screenshots (`--shots`,
with the commands in its header), and checks every file against Play's limits. The screenshots
are not committed (`out/` is ignored); they show the phone and tablet build on the renderer
phones use, at the Low graphics phones start with. The phone shots are 16:9 at 1920 x 1080 or
more, which Play asks of games for recommendations (at least three).

## Closed testing

| Field | Answer |
|---|---|
| Track | Closed testing |
| Testers | The owner's email list |
| Countries or regions | The owner's choice |
| Feedback URL or email for testers | flame2talon@gmail.com |
| App signing | Play App Signing with a Google-generated key; the upload key is stream A's |
| Release name | Play's default from the bundle: 1 (0.5.0) |
| Release notes | `store/release-notes.md` |

## Not answered here

- The public contact email and the developer name: read from Play Console.
- The testers' email list and the countries or regions of the test: the owner's choice.
- The exact tag names: Play's list may differ from the suggestions above.
- Questions Play adds after this was written: answer from the facts at the top, and ask when a
  question touches data, ads, purchases, AI or children.
