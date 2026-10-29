//! Public-domain lines for the DEEP WORK word stage and the Words game.
//!
//! Words are separated by single spaces. Only ASCII letters of each word are
//! typed (punctuation and apostrophes are shown but skipped), so every word
//! here contains at least one letter and no word is longer than 20 letters.

pub const Quote = struct {
    text: []const u8,
    by: []const u8,
};

pub const all = [_]Quote{
    .{ .text = "Well done is better than well said.", .by = "Benjamin Franklin, Poor Richard's Almanack" },
    .{ .text = "Lost time is never found again.", .by = "Benjamin Franklin, Poor Richard's Almanack" },
    .{ .text = "Little strokes fell great oaks.", .by = "Benjamin Franklin, Poor Richard's Almanack" },
    .{ .text = "Diligence is the mother of good luck.", .by = "Benjamin Franklin, The Way to Wealth" },
    .{ .text = "Energy and persistence conquer all things.", .by = "Benjamin Franklin" },
    .{ .text = "Our life is frittered away by detail. Simplify, simplify.", .by = "Henry David Thoreau, Walden" },
    .{ .text = "It is not enough to be busy. The question is: what are we busy about?", .by = "Henry David Thoreau, letter to H. G. O. Blake" },
    .{ .text = "Nothing great was ever achieved without enthusiasm.", .by = "Ralph Waldo Emerson, Circles" },
    .{ .text = "Finish each day and be done with it.", .by = "Ralph Waldo Emerson, letter to his daughter" },
    .{ .text = "To be great is to be misunderstood.", .by = "Ralph Waldo Emerson, Self-Reliance" },
    .{ .text = "Hitch your wagon to a star.", .by = "Ralph Waldo Emerson, Society and Solitude" },
    .{ .text = "Brevity is the soul of wit.", .by = "William Shakespeare, Hamlet" },
    .{ .text = "The readiness is all.", .by = "William Shakespeare, Hamlet" },
    .{ .text = "We know what we are, but know not what we may be.", .by = "William Shakespeare, Hamlet" },
    .{ .text = "Our doubts are traitors.", .by = "William Shakespeare, Measure for Measure" },
    .{ .text = "Nothing will come of nothing.", .by = "William Shakespeare, King Lear" },
    .{ .text = "The fault, dear Brutus, is not in our stars, but in ourselves.", .by = "William Shakespeare, Julius Caesar" },
    .{ .text = "There is nothing either good or bad, but thinking makes it so.", .by = "William Shakespeare, Hamlet" },
    .{ .text = "Begin at the beginning, and go on till you come to the end: then stop.", .by = "Lewis Carroll, Alice's Adventures in Wonderland" },
    .{ .text = "Sometimes I've believed as many as six impossible things before breakfast.", .by = "Lewis Carroll, Through the Looking-Glass" },
    .{ .text = "Experience is the name everyone gives to their mistakes.", .by = "Oscar Wilde, Lady Windermere's Fan" },
    .{ .text = "To live is the rarest thing in the world.", .by = "Oscar Wilde, The Soul of Man Under Socialism" },
    .{ .text = "Truth is stranger than fiction.", .by = "Mark Twain, Following the Equator" },
    .{ .text = "Hope is the thing with feathers.", .by = "Emily Dickinson" },
    .{ .text = "Knowledge is power.", .by = "Francis Bacon, Meditationes Sacrae" },
    .{ .text = "To err is human, to forgive divine.", .by = "Alexander Pope, An Essay on Criticism" },
    .{ .text = "A little learning is a dangerous thing.", .by = "Alexander Pope, An Essay on Criticism" },
    .{ .text = "The pen is mightier than the sword.", .by = "Edward Bulwer-Lytton, Richelieu" },
    .{ .text = "I took the one less traveled by, and that has made all the difference.", .by = "Robert Frost, The Road Not Taken" },
    .{ .text = "It was the best of times, it was the worst of times.", .by = "Charles Dickens, A Tale of Two Cities" },
    .{ .text = "I celebrate myself, and sing myself.", .by = "Walt Whitman, Song of Myself" },
    .{ .text = "Do I contradict myself? Very well then I contradict myself.", .by = "Walt Whitman, Song of Myself" },
    .{ .text = "Practice is the best of all instructors.", .by = "Publilius Syrus" },
    .{ .text = "Fortune favors the bold.", .by = "Latin proverb" },
    .{ .text = "Make haste slowly.", .by = "Augustus, via Suetonius" },
    .{ .text = "A journey of a thousand miles begins beneath your feet.", .by = "Laozi, Tao Te Ching" },
    .{ .text = "Genius is one percent inspiration and ninety nine percent perspiration.", .by = "Thomas Edison" },
    .{ .text = "Measure twice, cut once.", .by = "Carpenter's proverb" },
    .{ .text = "Rome was not built in a day.", .by = "Medieval proverb" },
    .{ .text = "Where there is a will, there is a way.", .by = "English proverb" },
    .{ .text = "Fall seven times, stand up eight.", .by = "Japanese proverb" },
    .{ .text = "The early bird catches the worm.", .by = "English proverb" },
    .{ .text = "All happy families are alike; each unhappy family is unhappy in its own way.", .by = "Leo Tolstoy, Anna Karenina (Garnett translation)" },
    .{ .text = "The only way to get rid of a temptation is to yield to it.", .by = "Oscar Wilde, The Picture of Dorian Gray" },
    .{ .text = "The woods are lovely, dark and deep, but I have promises to keep.", .by = "Robert Frost, Stopping by Woods on a Snowy Evening" },
    .{ .text = "A thing of beauty is a joy for ever: its loveliness increases; it will never pass into nothingness.", .by = "John Keats, Endymion" },
    .{ .text = "Shall I compare thee to a summer's day? Thou art more lovely and more temperate.", .by = "William Shakespeare, Sonnet 18" },
    .{ .text = "All the world's a stage, and all the men and women merely players.", .by = "William Shakespeare, As You Like It" },
    .{ .text = "To be, or not to be: that is the question.", .by = "William Shakespeare, Hamlet" },
    .{ .text = "Tomorrow, and tomorrow, and tomorrow, creeps in this petty pace from day to day.", .by = "William Shakespeare, Macbeth" },
    .{ .text = "Some are born great, some achieve greatness, and some have greatness thrust upon them.", .by = "William Shakespeare, Twelfth Night" },
    .{ .text = "Now is the winter of our discontent made glorious summer by this sun of York.", .by = "William Shakespeare, Richard III" },
    .{ .text = "It is a far, far better thing that I do, than I have ever done.", .by = "Charles Dickens, A Tale of Two Cities" },
    .{ .text = "Whatever our souls are made of, his and mine are the same.", .by = "Emily Bronte, Wuthering Heights" },
    .{ .text = "I am no bird; and no net ensnares me.", .by = "Charlotte Bronte, Jane Eyre" },
    .{ .text = "Heaven is under our feet as well as over our heads.", .by = "Henry David Thoreau, Walden" },
    .{ .text = "I wandered lonely as a cloud that floats on high o'er vales and hills.", .by = "William Wordsworth" },
    .{ .text = "Ah, but a man's reach should exceed his grasp, or what's a heaven for?", .by = "Robert Browning, Andrea del Sarto" },
    .{ .text = "Water, water, every where, nor any drop to drink.", .by = "Samuel Taylor Coleridge, The Rime of the Ancient Mariner" },
    .{ .text = "Hope springs eternal in the human breast.", .by = "Alexander Pope, An Essay on Man" },
    .{ .text = "While we are postponing, life speeds by.", .by = "Seneca, Moral Letters to Lucilius" },
    .{ .text = "The unexamined life is not worth living.", .by = "Plato, Apology" },
    .{ .text = "Life is a long lesson in humility.", .by = "J. M. Barrie, The Little Minister" },
};

/// Number of words (space-separated tokens) in `text`.
pub fn wordCount(text: []const u8) usize {
    var n: usize = 0;
    var in_word = false;
    for (text) |c| {
        if (c == ' ') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            n += 1;
        }
    }
    return n;
}

const std = @import("std");

test "quotes are well formed" {
    for (all) |q| {
        const n = wordCount(q.text);
        try std.testing.expect(n >= 2 and n <= 64);
        var it = std.mem.tokenizeScalar(u8, q.text, ' ');
        while (it.next()) |w| {
            var letters: usize = 0;
            for (w) |c| {
                if (std.ascii.isAlphabetic(c)) letters += 1;
            }
            try std.testing.expect(letters >= 1 and letters <= 20);
        }
    }
}
