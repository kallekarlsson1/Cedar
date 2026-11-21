"""Generates the test library in evals/corpus.noindex: papers with author blocks and reference lists, notes,
a duplicate, a text copy of a PDF and an image-only PDF. Generic made-up titles, names and abstracts; the body text is lorem ipsum.

    uvx --with pymupdf python evals/make_corpus.py evals/corpus.noindex
"""

import sys
from pathlib import Path

import pymupdf

# (file name, title, authors, year, abstract)
PAPERS = [
    ("smith_cycling.pdf", "Commuting by Bicycle in Mid-Sized Cities", ["John Smith", "Maria Garcia"], 2026,
     "We asked office workers in three towns how they travel to work. People who cycled arrived on time more "
     "often than those who drove, and reported feeling more awake in the morning. Rain was the main reason for "
     "leaving the bike at home."),
    ("report-0193.pdf", "Watering Schedules for Indoor Tomato Plants", ["Anna Lee", "David Brown"], 2025,
     "Tomato plants on a windowsill were watered daily, every third day, or weekly. Plants watered every third "
     "day gave the most fruit. Daily watering caused yellow leaves and root rot."),
    ("office_noise.pdf", "Noise Levels in Open-Plan Offices", ["Emma Wilson", "James Taylor"], 2023,
     "Sound meters recorded a week of conversations, phone calls and keyboard clatter in a shared workspace. "
     "Staff seated near the kitchen made more mistakes in a proofreading task than staff in quiet corners."),
    ("phone_battery.pdf", "Battery Life of Budget Smartphones", ["Sarah Johnson"], 2020,
     "Twelve low-cost handsets played video on repeat until they shut down. Screen brightness mattered more "
     "than processor speed, and two models lasted a full day."),
    ("night_reading.pdf", "Reading Habits of Night-Shift Workers", ["Michael Davis"], 2020,
     "Nurses and security guards kept diaries of what they read during breaks. Short stories and news were "
     "preferred over novels, and most reading happened on a phone."),
    ("snow_depth.pdf", "Snow Depth Measurements on a Mountain Pass", ["Laura Martin", "Peter Clark"], 2019,
     "A row of marked poles was photographed every morning for one winter. Wind moved more snow than fell from "
     "the sky, and drifts on the eastern side were twice as deep."),
    ("bread_fermentation.pdf", "Fermentation Times for Homemade Bread", ["Lisa White"], 2021,
     "Dough was left to rise for two, eight or twenty hours before baking. Longer rising gave a sourer taste "
     "and larger holes in the crumb, and a cool kitchen slowed everything down."),
    ("garden_bees.pdf", "How Garden Bees Find Their Way Home", ["Peter Clark", "John Smith"], 2018,
     "Marked bees were carried in a box to different spots around a village and released. Most returned to the "
     "hive within an hour unless they were let go beyond the river."),
    ("background_jobs.pdf", "Handling Interrupted Tasks in Background Jobs", ["David Brown"], 2024,
     "A program that is stopped halfway through saving can leave its data half-written. We list the steps "
     "where stopping loses data and suggest writing to a temporary file first."),
    ("naps_recall.pdf", "Afternoon Naps and Word Recall", ["Jane Doe"], 2017,
     "Students who slept for half an hour after studying a list of foreign words remembered more of them a "
     "week later than students who stayed awake."),
]
# Every paper cites Smith, who is an author of only two.
CITES = ["Smith, J., & Garcia, M. (2026). Commuting by bicycle in mid-sized cities. Example Journal.",
         "Doe, J. (2017). Afternoon naps and word recall. Example Journal.",
         "Wilson, E. (2023). Noise levels in open-plan offices. Example Reports."]
NOTES = [
    ("Meeting notes 12 March.md", "# Meeting notes 12 March\n\nBudget for the field trip approved. Alex books the "
     "minibus; invoice number INV-20417 goes to accounting. Next meeting in April.\n"),
    ("Recipe - cardamom buns.md", "# Cardamom buns\n\nWarm the milk, crumble in the yeast, knead in butter and "
     "crushed cardamom. Proof twice, bake at 225 degrees for eight minutes.\n"),
    ("Reading list.md", "---\ntitle: Reading list for the seminar\nauthor: someone\n---\n\n- Smith on cycling\n"
     "- Wilson on office noise\n- the bread paper, for fun\n"),
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
           " Earlier work by Smith et al. and by Doe frames the question."
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
    paper(out / "papers" / "smith_cycling (1).pdf", *PAPERS[0][1:])
    (out / "notes" / "smith_cycling.txt").write_text(PAPERS[0][1] + "\n" + "\n".join(PAPERS[0][2]) + "\n" + " ".join([PAPERS[0][4]] * 6))
    paper(out / "papers" / "scan_0042.pdf", "Water Mills on a Tidal River", ["Thomas Green"], 1998,
          "Millers stored water behind a gate at high tide and let it out through a wheel as the river fell. "
          "Old account books record how many sacks of grain each mill ground per month.", scanned=True)
    for name, text in NOTES:
        (out / "notes" / name).write_text(text)
    print("wrote", sum(1 for _ in out.rglob("*") if _.is_file()), "files to", out)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
