/// Which Firestore project and collection the locator lives in.
///
/// **These are not secrets, and treating them as if they were would be the
/// mistake.** A Firebase web `apiKey` ships inside every client that talks to
/// the project — it names the project, it does not authorise anything. What
/// keeps a computer's address private is the rules plus a 100-bit token nobody
/// else holds, exactly as `me-truyen-chu/docs/dong-bo-khong-can-be.md` records
/// for the same project.
///
/// The project is shared with the GroupMe apps rather than newly created, so
/// nothing has to be stood up or paid for. Two things follow from that and
/// neither is optional:
///
/// - **Grid gets its own collection.** Mixing this into `/sync/{id}` would work
///   — the shapes happen to match — and would mean a tidy-up in either product
///   deleting the other's rows.
/// - **The quota is shared.** 20k writes and 50k reads a day is a *project*
///   ceiling, so Grid spending it is an outage for four shipped apps. That is
///   the argument for the locator holding one address and for a write happening
///   only when the address actually changed.
///
/// The rules that have to be published for [kLocatorCollection] are in
/// `docs/phone-link.md`; a 403 from a write is almost always that they were not.
library;

/// The Firebase project that holds the locator.
const String kLocatorProjectId = 'me-truyen-chu';

/// The project's web API key — public by design, see the library comment.
const String kLocatorApiKey = 'AIzaSyDMhdI4N-Bl7ZqjukfqmVu0YcbzgD2bBPA';

/// Grid's own collection inside that project.
const String kLocatorCollection = 'grid_phone';
