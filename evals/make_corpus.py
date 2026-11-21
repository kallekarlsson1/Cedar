"""Generates the test library in evals/corpus.noindex: papers with author blocks and reference lists, notes,
a duplicate, a text copy of a PDF and an image-only PDF. All names, titles and abstracts are invented; the body text is lorem ipsum.

    uvx --with pymupdf python evals/make_corpus.py evals/corpus.noindex
"""

import sys
from pathlib import Path

import pymupdf

# (file name, title, authors, year, abstract)
PAPERS = [
    ("halvorsen_plural.pdf", "Human Reasoning under Plural Assistant Support", ["Mira Halvorsen", "Tobias Renner"], 2026,
     "We study how people solve mathematics problems and write essays when several language models help them at "
     "the same time. Participants who consulted multiple assistants compared the answers and relied less on any "
     "single one. Open-ended writing became more varied, while arithmetic accuracy stayed the same."),
    ("report-0193.pdf", "Quiet Saboteurs: Flattering Assistants Mislead Beginners", ["Noor Castellan", "Eamon Park"], 2025,
     "Assistants that flatter the user and agree with wrong ideas harm beginners during debugging tasks. Novices "
     "who received agreeable but incorrect feedback kept their mistakes longer than those who were challenged."),
    ("debate_judges.pdf", "Adversarial Debate Helps Judges Find the Truth", ["Lucien Marsh", "Odile Farrow"], 2023,
     "Two experts argue opposite sides of a reading comprehension question while a judge without access to the "
     "story decides who is right. Judges reach the truth more often from an adversarial exchange than from a "
     "single consultant."),
    ("conformity_online.pdf", "Social Presence and Conformity in Online Quizzes", ["Ilse Drummond"], 2020,
     "People change their quiz answers to match the majority shown on screen. The effect grows with the size of "
     "the group and shrinks when answers are anonymous."),
    ("worked_examples.pdf", "Learning from Erroneous Examples in the Physics Classroom", ["Karim Belhadj"], 2020,
     "Eighth graders studying electric circuits diagnosed mistakes in flawed solutions. Contrasting incorrect "
     "solutions with correct ones improved conceptual understanding more than studying correct ones alone."),
    ("glacier_melt.pdf", "Meltwater Routing beneath Alpine Glaciers", ["Ingrid Solheim", "Paolo Ferrante"], 2019,
     "Dye tracing shows that water under mountain ice moves through channels that reorganize every summer. "
     "Drainage speed controls how fast the ice slides downhill."),
    ("sourdough.pdf", "Microbial Succession in Sourdough Starters", ["Mei Tanaka"], 2021,
     "Wild yeast and lactic acid bacteria replace each other over the first two weeks of a flour and water "
     "culture. Feeding schedule and temperature decide which species dominate and how sour the bread tastes."),
    ("bee_navigation.pdf", "Path Integration in Foraging Honeybees", ["Tomasz Zielinski", "Mira Halvorsen"], 2018,
     "Bees returning to the hive estimate distance from the image motion they experience in flight. Narrow "
     "tunnels with patterned walls make them overestimate how far they have flown."),
    ("rust_async.pdf", "Cancellation Safety in Asynchronous Rust", ["Dana Whitfield"], 2024,
     "Dropping a future at an await point can leave shared state half-updated. We classify library functions by "
     "whether interruption loses data and propose a lint that flags unsafe select branches."),
    ("sleep_memory.pdf", "Slow-Wave Sleep and Vocabulary Retention", ["Aoife Brennan"], 2017,
     "Students who napped after studying foreign words remembered more a week later. Time spent in deep sleep "
     "predicted the benefit; total nap length did not."),
]
# Every paper cites Halvorsen, who is an author of only two.
CITES = ["Halvorsen, M., & Renner, T. (2026). Human reasoning under plural assistant support. Proceedings of the Made-Up Conference.",
         "Brennan, A. (2017). Slow-wave sleep and vocabulary retention. Journal of Sleep Research.",
         "Marsh, L. (2023). Adversarial debate helps judges find the truth. Invented Preprints."]
NOTES = [
    ("Meeting notes 12 March.md", "# Meeting notes 12 March\n\nBudget for the field trip approved. Lena books the "
     "minibus; invoice number INV-20417 goes to accounting. Next meeting in April.\n"),
    ("Recipe - cardamom buns.md", "# Cardamom buns\n\nWarm the milk, crumble in the yeast, knead in butter and "
     "crushed cardamom. Proof twice, bake at 225 degrees for eight minutes.\n"),
    ("Reading list.md", "---\ntitle: Reading list for the seminar\nauthor: someone\n---\n\n- Halvorsen on several "
     "assistants\n- Marsh on debate\n- the sourdough paper, for fun\n"),
    ("Anteckningar svenska.md", "# Anteckningar om isbildning\n\nSjöisen lägger sig först i vikarna. Tjockleken "
     "mäts med borr varje vecka under vintern.\n"),
]


LOREM = ("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et "
         "dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex "
         "ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu "
         "fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt "
         "mollit anim id est laborum. Curabitur pretium tincidunt lacus, nulla gravida orci a odio. Nullam varius, "
         "turpis et commodo pharetra, est eros bibendum elit, nec luctus magna felis sollicitudin mauris. Integer in "
         "mauris eu nibh euismod gravida. Duis ac tellus et risus vulputate vehicula. Donec lobortis risus a elit. "
         "Etiam tempor. Ut ullamcorper, ligula eu tempor congue, eros est euismod turpis, id tincidunt sapien risus "
         "a quam. Maecenas fermentum consequat mi. Donec fermentum. Pellentesque malesuada nulla a mi. Duis sapien "
         "sem, aliquet nec, commodo eget, consequat quis, neque. Aliquam faucibus, elit ut dictum aliquet, felis "
         "nisl adipiscing sapien, sed malesuada diam lacus eget erat.").split(". ")


def filler(seed: str, sentences: int) -> str:
    """Placeholder body text, in a different sentence order for each document."""
    order = sorted(range(len(LOREM)), key=lambda i: hash_of(seed, i))
    return ". ".join(LOREM[order[i % len(order)]].rstrip(".") for i in range(sentences)) + "."


def hash_of(seed: str, i: int) -> int:
    import zlib
    return zlib.crc32(f"{seed}-{i}".encode())


def paper(path: Path, title: str, authors: list[str], year: int, about: str, scanned: bool = False):
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_textbox(pymupdf.Rect(60, 60, 535, 130), title, fontsize=18, fontname="hebo", align=1)
    page.insert_textbox(pymupdf.Rect(60, 135, 535, 190), "\n".join(authors) + f"\nUniversity of Somewhere, {year}",
                        fontsize=10, align=1)
    body = "Abstract\n" + about + "\n\n1 Introduction\n" + filler(title, 16) + \
           " Earlier work by Halvorsen et al. and by Brennan frames the question."
    page.insert_textbox(pymupdf.Rect(60, 200, 535, 780), body, fontsize=10)
    page2 = doc.new_page()
    page2.insert_textbox(pymupdf.Rect(60, 60, 535, 400), "2 Results\n" + filler(title + "results", 14), fontsize=10)
    page2.insert_textbox(pymupdf.Rect(60, 420, 535, 780), "References\n" + "\n".join(CITES), fontsize=9)
    if scanned:   # rasterize the pages so there is no text layer
        flat = pymupdf.open()
        for p in doc:
            pix = p.get_pixmap(dpi=150)
            flat.new_page(width=p.rect.width, height=p.rect.height).insert_image(p.rect, pixmap=pix)
        doc = flat
    doc.save(path)


def main(out: Path):
    (out / "papers").mkdir(parents=True, exist_ok=True)
    (out / "notes").mkdir(exist_ok=True)
    for name, title, authors, year, about in PAPERS:
        paper(out / "papers" / name, title, authors, year, about)
    # A duplicate, a text copy and a scan.
    paper(out / "papers" / "halvorsen_plural (1).pdf", *PAPERS[0][1:])
    (out / "notes" / "halvorsen_plural.txt").write_text(PAPERS[0][1] + "\n" + "\n".join(PAPERS[0][2]) + "\n" + " ".join([PAPERS[0][4]] * 6))
    paper(out / "papers" / "scan_0042.pdf", "Tidal Mills of the Brittany Coast", ["Yann Le Goff"], 1998,
          "Medieval millers stored seawater behind a dike at high tide and released it through a wheel as the "
          "sea fell. Surviving ledgers record how much grain each mill ground per lunar month.", scanned=True)
    for name, text in NOTES:
        (out / "notes" / name).write_text(text)
    print("wrote", sum(1 for _ in out.rglob("*") if _.is_file()), "files to", out)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
