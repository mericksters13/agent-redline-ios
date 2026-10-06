extension Recipe {
    /// The recipe the Tonight tab shows.
    static let tonight = Recipe(
        id: "lemon-herb-chicken",
        name: "Lemon Herb Chicken",
        summary: "Weeknight dinner, roasted on one tray",
        symbol: "oven",
        course: .dinner,
        cuisine: "Mediterranean",
        minutes: 55,
        servings: 4,
        calories: 480,
        difficulty: .easy,
        about: """
            Chicken thighs, potatoes and red onions roast together on one tray, so there is one thing to wash up \
            and every part of the meal is ready at the same time. A marinade of lemon zest, garlic, oregano and \
            olive oil does most of the work: give it twenty minutes if you have them, or put it on the night before. \
            The potatoes go in first so they crisp at the edges, then the chicken sits on top and its juices run \
            into them as it cooks. Squeeze the roasted lemon halves over everything at the end, and finish with a \
            handful of parsley and a spoonful of yogurt. Leftovers keep for three days and are good cold in a wrap \
            the next day.
            """,
        ingredients: [
            "8 bone-in chicken thighs",
            "800 g small potatoes, halved",
            "2 red onions, cut into wedges",
            "2 lemons",
            "4 garlic cloves, grated",
            "2 tsp dried oregano",
            "4 tbsp olive oil",
            "Parsley and yogurt, to serve",
        ],
        steps: [
            "Mix the zest and juice of one lemon with the garlic, oregano, olive oil and salt, and coat the chicken.",
            "Heat the oven to 220°C. Toss the potatoes and onions in oil and roast for 15 minutes.",
            "Lay the chicken on the potatoes, skin side up, with the second lemon cut in half.",
            "Roast for 35 to 40 minutes, until the skin is crisp and the juices run clear.",
            "Squeeze the roasted lemon over the tray, scatter the parsley and serve with yogurt.",
        ]
    )

    /// Every recipe in the demo, Tonight's included.
    static let samples: [Recipe] = [
        Recipe(
            id: "green-shakshuka",
            name: "Green Shakshuka",
            summary: "Eggs baked in spinach, leeks and feta",
            symbol: "frying.pan",
            course: .breakfast,
            cuisine: "North African",
            minutes: 30,
            servings: 4,
            calories: 320,
            difficulty: .easy,
            about: """
                A green take on the North African classic. Leeks and spinach cook down with cumin and a little \
                chili until they collapse into a loose, savory base, then the eggs go into small wells and set \
                gently under a lid. Crumbled feta and a handful of soft herbs finish it. It comes together in one \
                pan in about half an hour, which makes it as good for a slow weekend breakfast as for a quick \
                dinner. Serve it straight from the pan with warm flatbread or toasted sourdough to scoop up the \
                greens and the soft yolks.
                """,
            ingredients: [
                "2 leeks, thinly sliced",
                "300 g spinach",
                "2 garlic cloves, sliced",
                "1 tsp ground cumin",
                "A pinch of chili flakes",
                "6 eggs",
                "100 g feta",
                "Dill and parsley",
                "Flatbread, to serve",
            ],
            steps: [
                "Soften the leeks in olive oil over medium heat for 8 minutes.",
                "Add the garlic, cumin and chili, and cook for 1 minute.",
                "Stir in the spinach a handful at a time until it wilts, then season.",
                "Make six wells, crack an egg into each, cover and cook for 6 to 8 minutes, until the whites set.",
                "Scatter the feta and herbs over the top and serve from the pan.",
            ]
        ),
        Recipe(
            id: "buttermilk-pancakes",
            name: "Buttermilk Pancakes",
            summary: "Fluffy weekend stack",
            symbol: "sun.max",
            course: .breakfast,
            cuisine: "American",
            minutes: 25,
            servings: 4,
            calories: 410,
            difficulty: .easy,
            about: """
                Buttermilk makes these pancakes tender and gives them a slight tang that balances maple syrup. The \
                batter should stay lumpy: mix it only until the flour disappears, then let it rest for five \
                minutes while the pan heats, so the baking soda starts to work. Cook them on a medium heat with \
                very little butter, and flip each one when bubbles cover the top and the edges look dry. Keep the \
                finished ones warm in a low oven, loosely covered, until the whole stack is ready. If you have no \
                buttermilk, stir a tablespoon of lemon juice into regular milk and leave it for ten minutes.
                """,
            ingredients: [
                "250 g plain flour",
                "2 tbsp sugar",
                "1 tsp baking soda",
                "1 tsp baking powder",
                "450 ml buttermilk",
                "2 eggs",
                "40 g melted butter",
                "Maple syrup, to serve",
            ],
            steps: [
                "Whisk the flour, sugar, baking soda, baking powder and a pinch of salt in a large bowl.",
                "Whisk the buttermilk, eggs and melted butter, pour into the dry mix and stir until just combined.",
                "Rest the batter for 5 minutes while a pan heats over medium heat.",
                "Cook ladles of batter for 2 minutes a side, flipping when bubbles cover the top.",
                "Serve warm with maple syrup.",
            ]
        ),
        Recipe(
            id: "chai-porridge",
            name: "Spiced Chai Porridge",
            summary: "Oats simmered with cardamom, ginger and cinnamon",
            symbol: "mug",
            course: .breakfast,
            cuisine: "Indian",
            minutes: 15,
            servings: 2,
            calories: 290,
            difficulty: .easy,
            about: """
                Everything that goes into a cup of masala chai, cooked into a bowl of oats. Crushed cardamom, a \
                cinnamon stick, fresh ginger and a couple of black peppercorns simmer in milk for a few minutes \
                before the oats go in, so the spices flavor the whole pot rather than sitting on top. A spoon of \
                brown sugar or honey rounds it out. Top it with sliced banana and toasted almonds, or with yogurt \
                and a little more cinnamon. It reheats well with a splash of milk, so a double batch covers two \
                mornings.
                """,
            ingredients: [
                "100 g rolled oats",
                "500 ml milk",
                "4 cardamom pods, crushed",
                "1 cinnamon stick",
                "A thumb of ginger, grated",
                "2 black peppercorns",
                "1 tbsp brown sugar",
                "Banana and almonds, to serve",
            ],
            steps: [
                "Simmer the milk with the cardamom, cinnamon, ginger and peppercorns for 5 minutes.",
                "Strain out the whole spices and return the milk to the pan.",
                "Stir in the oats and cook for 5 minutes, stirring often, until thick.",
                "Sweeten with the sugar and serve with banana and almonds.",
            ]
        ),
        tonight,
        Recipe(
            id: "miso-salmon",
            name: "Miso Glazed Salmon",
            summary: "Sweet and salty glaze, broiled in 10 minutes",
            symbol: "fish",
            course: .dinner,
            cuisine: "Japanese",
            minutes: 20,
            servings: 2,
            calories: 450,
            difficulty: .easy,
            about: """
                White miso, mirin and a little honey make a glaze that caramelizes under the grill in the time it \
                takes the salmon to cook through. Brush it on thickly and keep the fish close to the heat, watching \
                it for the last two minutes: the sugars go from glossy to burnt quickly. The flesh stays moist \
                because the glaze seals the top. Serve it over rice with something crisp and green, such as \
                blanched bok choy or a cucumber salad dressed with rice vinegar and sesame. Any leftover glaze \
                keeps in the fridge for a week and works just as well on eggplant or tofu.
                """,
            ingredients: [
                "2 salmon fillets",
                "2 tbsp white miso",
                "1 tbsp mirin",
                "1 tsp honey",
                "1 tsp soy sauce",
                "Sesame seeds and spring onions",
                "Steamed rice, to serve",
            ],
            steps: [
                "Heat the grill to high and line a tray with foil.",
                "Mix the miso, mirin, honey and soy sauce into a thick paste.",
                "Brush the paste over the salmon and grill for 8 to 10 minutes, without turning.",
                "Scatter with sesame seeds and spring onions, and serve over rice.",
            ]
        ),
        Recipe(
            id: "mushroom-risotto",
            name: "Mushroom Risotto",
            summary: "Creamy rice with three kinds of mushroom",
            symbol: "stove",
            course: .dinner,
            cuisine: "Italian",
            minutes: 45,
            servings: 4,
            calories: 520,
            difficulty: .medium,
            about: """
                A good risotto needs attention more than skill. Toast the rice in butter until the grains turn \
                translucent at the edges, add the wine, then feed in hot stock a ladle at a time, stirring so the \
                starch comes out and thickens the liquid. Dried porcini soaked in hot water give the dish its depth, \
                and their soaking liquid goes into the stock. Fresh chestnut and oyster mushrooms are fried hard in \
                a separate pan so they brown instead of steaming, and they go on top at the end. Finish with cold \
                butter and parmesan off the heat, and let it rest for two minutes before serving.
                """,
            ingredients: [
                "320 g arborio rice",
                "20 g dried porcini",
                "400 g chestnut and oyster mushrooms",
                "1 onion, finely chopped",
                "150 ml dry white wine",
                "1.2 l hot vegetable stock",
                "60 g butter",
                "60 g parmesan, grated",
            ],
            steps: [
                "Soak the porcini in 200 ml of boiling water for 15 minutes, then chop them and keep the liquid.",
                "Soften the onion in half the butter, add the rice and toast it for 2 minutes.",
                "Add the wine and let it bubble away, then add the stock and porcini liquid a ladle at a time.",
                "Meanwhile, fry the fresh mushrooms in a hot pan until browned.",
                "After about 18 minutes, take the rice off the heat and beat in the remaining butter and the parmesan.",
                "Rest for 2 minutes, then serve with the fried mushrooms on top.",
            ]
        ),
        Recipe(
            id: "chicken-pho",
            name: "Chicken Pho",
            summary: "Slow broth with star anise and fresh herbs",
            symbol: "flame",
            course: .dinner,
            cuisine: "Vietnamese",
            minutes: 150,
            servings: 6,
            calories: 430,
            difficulty: .involved,
            about: """
                The broth is the whole dish, and it takes time rather than effort. Charring the onion and ginger \
                over a flame first gives the stock its sweetness and color, and toasting the star anise, cloves, \
                cinnamon and coriander seeds wakes them up before they go into the pot. A whole chicken simmers \
                gently, never boiling, so the broth stays clear; skim it often in the first half hour. Season it at \
                the end with fish sauce and a little sugar. The noodles, shredded chicken and a pile of fresh \
                herbs, bean sprouts and lime go into each bowl, and the hot broth is ladled over at the table.
                """,
            ingredients: [
                "1 whole chicken, about 1.6 kg",
                "2 onions, halved",
                "A large piece of ginger",
                "3 star anise, 4 cloves, 1 cinnamon stick",
                "1 tbsp coriander seeds",
                "3 tbsp fish sauce",
                "400 g flat rice noodles",
                "Thai basil, mint, bean sprouts and lime",
            ],
            steps: [
                "Char the onions and ginger over a gas flame or under the grill until blackened in places.",
                "Toast the whole spices in a dry pan until fragrant, then tie them in a muslin bag.",
                "Cover the chicken with cold water, bring to a simmer and skim for 30 minutes.",
                "Add the onions, ginger and spices and simmer gently for 1 hour 30 minutes.",
                "Lift out the chicken, shred the meat and season the broth with fish sauce and sugar.",
                "Soak the noodles, divide them between bowls with the chicken, ladle over the broth and add the herbs.",
            ]
        ),
        Recipe(
            id: "black-bean-tacos",
            name: "Black Bean Tacos",
            summary: "Smoky beans, quick pickled onions and lime",
            symbol: "takeoutbag.and.cup.and.straw",
            course: .lunch,
            cuisine: "Mexican",
            minutes: 25,
            servings: 4,
            calories: 390,
            difficulty: .easy,
            about: """
                Canned black beans become a filling with real depth when they are fried with chipotle, cumin and \
                garlic and then mashed lightly, so some stay whole. The pickled onions take five minutes to make \
                and are ready by the time everything else is: slice them thin, cover them with lime juice and a \
                pinch of salt and sugar, and they turn bright pink. Warm the tortillas directly over a gas flame or \
                in a dry pan until they char in spots. Add avocado, crumbled cheese and a few leaves of coriander, \
                and set out hot sauce so everyone can choose their own heat.
                """,
            ingredients: [
                "2 cans black beans, drained",
                "1 chipotle in adobo, chopped",
                "1 tsp ground cumin",
                "2 garlic cloves",
                "1 red onion, thinly sliced",
                "3 limes",
                "12 small corn tortillas",
                "Avocado, feta and coriander",
            ],
            steps: [
                "Cover the onion with the juice of two limes, a pinch of salt and a pinch of sugar.",
                "Fry the garlic, cumin and chipotle in oil for 1 minute, add the beans and a splash of water.",
                "Cook for 5 minutes, then mash about half of the beans.",
                "Warm the tortillas in a dry pan and fill with the beans, onions, avocado, feta and coriander.",
            ]
        ),
        Recipe(
            id: "roasted-carrot-soup",
            name: "Roasted Carrot Soup",
            summary: "Carrots, ginger and coconut milk",
            symbol: "carrot",
            course: .lunch,
            cuisine: "Thai",
            minutes: 50,
            servings: 6,
            calories: 260,
            difficulty: .easy,
            about: """
                Roasting the carrots before they go into the pot makes this soup much sweeter and deeper than \
                boiling them would. They come out of the oven with browned edges, then simmer briefly with \
                ginger, garlic, a spoon of red curry paste and stock before being blended smooth. Coconut milk \
                goes in at the end for body, and lime juice brightens it. The soup should be thick enough to coat \
                a spoon; add more stock if it is too heavy. It freezes well for up to three months, so it is worth \
                making the full batch even for two people.
                """,
            ingredients: [
                "1 kg carrots, in chunks",
                "1 onion, chopped",
                "A thumb of ginger",
                "2 garlic cloves",
                "1 tbsp red curry paste",
                "800 ml vegetable stock",
                "400 ml coconut milk",
                "1 lime",
            ],
            steps: [
                "Roast the carrots with oil and salt at 200°C for 30 minutes, until browned at the edges.",
                "Soften the onion, ginger and garlic in a large pan, then stir in the curry paste.",
                "Add the carrots and stock and simmer for 10 minutes.",
                "Blend until smooth, stir in the coconut milk and season with lime juice and salt.",
            ]
        ),
        Recipe(
            id: "charred-corn-salad",
            name: "Charred Corn Salad",
            summary: "Summer corn, tomatoes, basil and lime",
            symbol: "leaf",
            course: .lunch,
            cuisine: "American",
            minutes: 20,
            servings: 4,
            calories: 240,
            difficulty: .easy,
            about: """
                The best version of this salad is made in late summer, when corn is sweet enough to eat raw. \
                Charring the kernels in a very hot, dry pan adds a smoky edge; leave them alone long enough to \
                blacken in spots before you stir. Ripe tomatoes, a little red onion and plenty of basil go in once \
                the corn has cooled slightly, and a dressing of lime, olive oil and a pinch of chili brings it \
                together. Add crumbled feta or diced avocado to make it a full lunch. It holds for a few hours at \
                room temperature, which makes it a good salad to bring to someone else's table.
                """,
            ingredients: [
                "4 ears of corn",
                "300 g cherry tomatoes, halved",
                "Half a red onion, finely diced",
                "A large handful of basil",
                "2 limes",
                "3 tbsp olive oil",
                "A pinch of chili flakes",
            ],
            steps: [
                "Cut the kernels off the cobs.",
                "Char the corn in a very hot dry pan for 6 to 8 minutes, stirring only now and then.",
                "Whisk the lime juice, olive oil, chili and salt.",
                "Toss the corn with the tomatoes, onion, basil and dressing.",
            ]
        ),
        Recipe(
            id: "olive-oil-cake",
            name: "Olive Oil Cake",
            summary: "Moist citrus cake that keeps for days",
            symbol: "birthday.cake",
            course: .dessert,
            cuisine: "Italian",
            minutes: 70,
            servings: 10,
            calories: 380,
            difficulty: .medium,
            about: """
                Olive oil keeps this cake moist for days longer than butter would, and its flavor sits quietly \
                behind the orange and lemon zest. Rubbing the zest into the sugar with your fingers releases the \
                oils and perfumes the whole cake. Whisk the eggs and sugar until pale and thick before the oil goes \
                in slowly, so the batter holds air and the crumb stays light. Use a fruity olive oil you would \
                happily eat on bread, not a peppery one. The cake is even better on the second day, served plain \
                with a dusting of icing sugar or with yogurt and berries.
                """,
            ingredients: [
                "3 eggs",
                "200 g sugar",
                "Zest of 1 orange and 1 lemon",
                "180 ml olive oil",
                "150 ml milk",
                "220 g plain flour",
                "2 tsp baking powder",
                "Icing sugar, to dust",
            ],
            steps: [
                "Heat the oven to 180°C and line a 23 cm round tin.",
                "Rub the zest into the sugar, then whisk with the eggs for 3 minutes until pale and thick.",
                "Pour in the olive oil slowly while whisking, then the milk.",
                "Fold in the flour and baking powder with a pinch of salt.",
                "Bake for 45 to 50 minutes, until a skewer comes out clean, and cool in the tin.",
            ]
        ),
        Recipe(
            id: "chocolate-mousse",
            name: "Dark Chocolate Mousse",
            summary: "Rich, airy and made a day ahead",
            symbol: "cup.and.saucer",
            course: .dessert,
            cuisine: "French",
            minutes: 30,
            servings: 6,
            calories: 340,
            difficulty: .medium,
            about: """
                Classic French mousse needs only chocolate, eggs and a little sugar. The texture depends on two \
                things: melting the chocolate gently so it stays glossy, and folding in the beaten egg whites with \
                a light hand so the air stays in. Use a chocolate of around 70 percent cocoa; anything darker can \
                turn the mousse bitter and dense. Spoon it into small glasses or cups, since it is rich, and chill \
                it for at least four hours or overnight. Serve it cold with a spoon of whipped cream, a few \
                raspberries or a pinch of flaky salt.
                """,
            ingredients: [
                "200 g dark chocolate, about 70 percent",
                "6 eggs, separated",
                "40 g sugar",
                "A pinch of salt",
                "Whipped cream and raspberries, to serve",
            ],
            steps: [
                "Melt the chocolate in a bowl over barely simmering water and let it cool for 5 minutes.",
                "Stir the egg yolks into the chocolate one at a time.",
                "Beat the egg whites with the salt to soft peaks, then beat in the sugar until glossy.",
                "Fold a third of the whites into the chocolate to loosen it, then fold in the rest gently.",
                "Spoon into six glasses and chill for at least 4 hours.",
            ]
        ),
    ]
}
