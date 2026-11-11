/// Decides whether a record an unattended run is about to create is one the
/// user already has.
///
/// A scheduled digest meets the same commitment more than once as a matter
/// of course: the follow-up message ("did you get the letters?"), the second
/// billing reminder, the batch a killed run had half-processed when Android
/// stopped its worker. Each time it writes the title afresh, so the copies
/// differ by a word or a dash - "Account Opening appointment - One Harbour
/// Place" three times on one afternoon - and an exact-match check never
/// fires. Titles are therefore compared by the words that carry meaning.
///
/// Applied only to unattended runs. Someone typing "add a task called test"
/// twice gets two tasks, because they are there to have meant it.
///
/// Conservative on purpose: a missed duplicate costs a swipe, a wrongly
/// merged task costs the thing the user was supposed to be reminded of.
/// "Sign account documents prepared by Marla Quinn" and "Sign and return
/// letters resent by Marla Quinn" share a verb and a name and are
/// different jobs; they score 0.33 and stay separate.
///
/// Which leaves the copy that was reworded past recognition. That one is
/// not decided here at all: [related] finds what the same sender already
/// has open, and the model is asked.
class DuplicateGuard {
  const DuplicateGuard._();

  /// Title similarity at or above which two open tasks are the same task.
  static const taskThreshold = 0.6;

  /// Lower for reminders and events, which must also share their exact
  /// time - that coincidence already carries most of the evidence.
  static const timedThreshold = 0.5;

  /// How far apart two due dates may be before same-titled tasks are
  /// treated as separate occurrences ("Pay rent", October and November).
  static const dueTolerance = Duration(hours: 24);

  static bool sameTask({
    required String title,
    DateTime? dueAt,
    required String existingTitle,
    DateTime? existingDueAt,
  }) {
    if (dueAt != null &&
        existingDueAt != null &&
        dueAt.difference(existingDueAt).abs() > dueTolerance) {
      return false;
    }
    return similarity(title, existingTitle) >= taskThreshold;
  }

  /// For records pinned to a moment: same minute, similar title.
  static bool sameTimed({
    required String title,
    required DateTime at,
    required String existingTitle,
    required DateTime existingAt,
  }) {
    if (at.difference(existingAt).abs() >= const Duration(minutes: 1)) {
      return false;
    }
    return similarity(title, existingTitle) >= timedThreshold;
  }

  /// How many of a sender's open tasks a held create is shown.
  static const relatedLimit = 3;

  /// Whether an open task from [sender] could be the one a new task is
  /// about: how many subject words their titles share, 0 when none or when
  /// they are plainly separate.
  ///
  /// A sender that repeats itself does not repeat its wording. The training
  /// reminder that read "1 past-due training assignment" at ten read
  /// "complete your assigned training" at eleven; the titles written from
  /// them share one word, score 0.29, and [sameTask] - rightly - lets both
  /// through. The device ended that morning with four open tasks for one
  /// course.
  ///
  /// This decides nothing. "Send the client list" and "Send the budget"
  /// come from one sender as well and are two jobs, and no count of words
  /// tells that pair from the reminders. The model that read the message
  /// can, so a create with a related task behind it is held once and shown
  /// what is already there (see `create_task`). What is counted is only
  /// what makes the question worth asking: a shared word that is neither
  /// the sender's own name nor the verb every task starts with.
  static int related({
    required String title,
    DateTime? dueAt,
    required String existingTitle,
    DateTime? existingDueAt,
    required String sender,
  }) {
    if (dueAt != null &&
        existingDueAt != null &&
        dueAt.difference(existingDueAt).abs() > dueTolerance) {
      return 0;
    }
    final left = tokens(title);
    final right = tokens(existingTitle);
    final leftNumbers = left.where(_isNumber).toSet();
    final rightNumbers = right.where(_isNumber).toSet();
    if (leftNumbers.isNotEmpty &&
        rightNumbers.isNotEmpty &&
        (leftNumbers.length != rightNumbers.length ||
            !leftNumbers.containsAll(rightNumbers))) {
      return 0;
    }
    final organization = _organizationOf(sender);
    final name = organization == null ? tokens(sender) : {organization};
    return left
        .intersection(right)
        .where((word) =>
            !_isNumber(word) &&
            !name.contains(word) &&
            !_taskVerbs.contains(word))
        .length;
  }

  /// Whether [text] names [sender].
  ///
  /// A task made from a message says who it came from - "Forwarded by Omar
  /// Reid", "(KnowBe4)" - and that is the only link between the two there
  /// is: the create is not told which message it came from. A name of one
  /// word is matched as written, so Flow the person is not the flow that
  /// stopped running. A longer one is matched on its words in any case and
  /// order, and may miss one of three or more: "Carla Mendes (Mechanic)"
  /// in the chat list is "Carla Mendes" in the task.
  static bool names(String text, String sender) {
    // Synced mail stores the address, and nobody writes a task "from
    // do-not-reply@training.knowbe4.com". What a task does say is the
    // organization, in its own capitals.
    final organization = _organizationOf(sender);
    if (organization != null) return _hasWord(text, organization, exact: false);
    final parts = _nameParts(sender);
    if (parts.isEmpty) return false;
    if (parts.length == 1) return _hasWord(text, parts.single, exact: true);
    final words = {
      for (final word in _nameParts(text)) word.toLowerCase(),
    };
    final found =
        parts.where((part) => words.contains(part.toLowerCase())).length;
    return found >= (parts.length <= 2 ? parts.length : 2);
  }

  static bool _hasWord(String text, String word, {required bool exact}) =>
      RegExp(
        '(?<![\\p{L}\\p{N}])${RegExp.escape(word)}(?![\\p{L}\\p{N}])',
        unicode: true,
        caseSensitive: exact,
      ).hasMatch(text);

  /// The part of an address that says who it is from: the domain's own
  /// name, or the mailbox when the domain is only where the mail is kept.
  /// Null when [sender] is not an address.
  static String? _organizationOf(String sender) {
    final address =
        RegExp(r'([^\s<>@]+)@([^\s<>@]+)').firstMatch(sender.toLowerCase());
    if (address == null) return null;
    final labels = address.group(2)!.split('.')
      ..removeWhere((label) => label.isEmpty);
    if (labels.length < 2) return null;
    labels.removeLast();
    if (labels.length > 1 && _secondLevel.contains(labels.last)) {
      labels.removeLast();
    }
    final name = labels.last;
    return _mailboxProviders.contains(name) ? address.group(1) : name;
  }

  static const _secondLevel = {'co', 'com', 'org', 'net', 'gov', 'edu', 'ac'};

  static const _mailboxProviders = {
    'gmail', 'googlemail', 'outlook', 'hotmail', 'live', 'msn', 'yahoo',
    'icloud', 'me', 'aol', 'proton', 'protonmail',
  };

  static List<String> _nameParts(String text) => text
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((part) =>
          part.length > 1 && !_stopwords.contains(part.toLowerCase()))
      .toList();

  /// Jaccard overlap of the titles' meaningful words, 0..1. Two titles with
  /// no meaningful words at all are only "the same" when they are equal.
  static double similarity(String a, String b) {
    final left = tokens(a);
    final right = tokens(b);
    if (left.isEmpty || right.isEmpty) {
      return a.trim().toLowerCase() == b.trim().toLowerCase() ? 1 : 0;
    }
    // Numbers are identifiers, not vocabulary. "Process invoice for July 20"
    // and "...July 27" share every word and are two invoices; "Task 1" and
    // "Task 2" likewise. When both titles carry numbers they must agree.
    final leftNumbers = left.where(_isNumber).toSet();
    final rightNumbers = right.where(_isNumber).toSet();
    if (leftNumbers.isNotEmpty &&
        rightNumbers.isNotEmpty &&
        (leftNumbers.length != rightNumbers.length ||
            !leftNumbers.containsAll(rightNumbers))) {
      return 0;
    }
    final shared = left.intersection(right).length;
    return shared / (left.length + right.length - shared);
  }

  static Set<String> tokens(String text) => text
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((token) =>
          _isNumber(token) ||
          (token.length > 1 && !_stopwords.contains(token)))
      .toSet();

  static bool _isNumber(String token) =>
      token.isNotEmpty && int.tryParse(token) != null;

  static const _stopwords = {
    'the', 'an', 'and', 'or', 'of', 'to', 'for', 'from', 'with', 'my', 'me',
    'in', 'on', 'at', 'by', 'is', 'are', 'it', 'this', 'that', 'your', 'you',
    'via', 'about', 'as', 'be', 're',
  };

  /// What a task title opens with. Two tasks that share only this share
  /// nothing: most of what one person asks for is to send something.
  static const _taskVerbs = {
    'send', 'check', 'review', 'complete', 'finish', 'reply', 'respond',
    'call', 'pay', 'follow', 'up', 'confirm', 'get', 'make', 'do', 'prepare',
    'submit', 'provide', 'update', 'contact', 'ask', 'arrange', 'handle',
    'look', 'into', 'sort', 'out',
  };
}
